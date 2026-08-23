package main

partial class LlvmTextEmitter {
    // A captured local lives in a heap cell so every closure sharing it
    // sees the same value; the alloca holds only the cell's address.
    fn cell_local(local: MirLocal) -> bool {
        return local.captured || local.escapes
    }

    // a fresh cell for one captured local, released with the closures
    // that share it; "" reports an unsupported capture layout
    fn cell_allocation(
        instruction: MirInstruction,
        local: MirLocal,
        register: string) -> string {
        let size: int = self.type_size(local.type)
        let mask: int =
            self.pointer_mask_at(local.type, 0)
        if size <= 0 || mask < 0 {
            self.fail(
                instruction,
                "LLVM emitter does not support capturing '{render_hir_type(local.type)}' yet")
            return ""
        }
        return "  {register} = call ptr @beans_alloc(i64 {size}, i64 {1 | (mask << 3)})\n"
    }

    fn emit_channel_new(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let element: HirType =
            instruction.type.args[0]
        if !self.handle_inner_supported(
             instruction, element, false) {
            return ""
        }
        let capacity: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        if self.wide_inline_value(element) {
            self.require_declare(
                "beans_chan_new_typed",
                "ptr @beans_chan_new_typed(i64, i64, i64)")
            return "  {result} = call ptr @beans_chan_new_typed(i64 {capacity}, i64 {self.type_size(element)}, i64 {self.pointer_mask_at(element, 0)})\n"
        }
        return "  {result} = call ptr @beans_chan_new(i64 {capacity}, i64 {self.slot_rc_flag(element)})\n"
    }

    // lock, hand the guarded value to the closure borrowed, unlock;
    // the mutex keeps its reference the whole time
    fn emit_mutex_with(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs a mutex and a closure")
            return ""
        }
        let receiver_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        if receiver_type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs the guarded type")
            return ""
        }
        let inner: HirType = receiver_type.args[0]
        if !self.handle_inner_supported(
             instruction, inner, true) {
            return ""
        }
        let llvm: string = self.type_text(inner)
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let closure: string =
            self.value(
                function, values,
                instruction.operands[1], instruction)
        let id: int = self.fresh()
        if self.wide_inline_value(inner) {
            let slot: string =
                self.spill_slot(
                    llvm, "mutex.value")
            self.require_declare(
                "beans_mutex_lock_typed",
                "void @beans_mutex_lock_typed(ptr, ptr, i64)")
            var arguments: List<string> =
                ["ptr {closure}"]
            let setup: string =
                self.append_internal_argument(
                    inner, "%with.value{id}",
                    arguments)
            return "  call void @beans_mutex_lock_typed(ptr {receiver}, ptr {slot}, i64 {self.type_size(inner)})\n  %with.value{id} = load {llvm}, ptr {slot}\n  %with.fn{id} = load ptr, ptr {closure}\n{setup}  call void %with.fn{id}({arguments.join(", ")})\n  call void @beans_mutex_unlock(ptr {receiver})\n"
        }
        let conversion: LlvmSlotConversion =
            self.from_slot(
                inner, "%with.raw{id}",
                "%with.value{id}", "with")
        var arguments: List<string> =
            ["ptr {closure}"]
        let setup: string =
            self.append_internal_argument(
                inner, conversion.value,
                arguments)
        return "  %with.raw{id} = call i64 @beans_mutex_lock(ptr {receiver})\n{conversion.setup}  %with.fn{id} = load ptr, ptr {closure}\n{setup}  call void %with.fn{id}({arguments.join(", ")})\n  call void @beans_mutex_unlock(ptr {receiver})\n"
    }

    // the queue owns sent values, and MIR releases the borrowed
    // temporary after this instruction, so references are retained in
    fn emit_channel_send(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 2 {
            self.fail(
                instruction,
                "LLVM emitter needs a channel and a value")
            return ""
        }
        let receiver_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        if receiver_type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs the element type")
            return ""
        }
        let element: HirType = receiver_type.args[0]
        if !self.handle_inner_supported(
             instruction, element, false) {
            return ""
        }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let value: string =
            self.value(
                function, values,
                instruction.operands[1], instruction)
        let id: int = self.fresh()
        let consumed: bool =
            instruction.consumes.len() >= 2 &&
            instruction.consumes[1]
        let retains: string =
            if consumed {
                ""
            } else {
                self.emit_arc_value(
                    element, value, true)
            }
        if self.wide_inline_value(element) {
            let llvm: string = self.type_text(element)
            let slot: string =
                self.spill_slot(
                    llvm, "channel.send")
            self.require_declare(
                "beans_chan_send_typed",
                "i64 @beans_chan_send_typed(ptr, ptr)")
            return "{retains}  store {llvm} {value}, ptr {slot}\n  %send.ok{id} = call i64 @beans_chan_send_typed(ptr {receiver}, ptr {slot})\n  %send.closed{id} = icmp eq i64 %send.ok{id}, 0\n  br i1 %send.closed{id}, label %send.panic{id}, label %send.done{id}\nsend.panic{id}:\n  call void @beans_panic(ptr {self.string_pointer("send on a closed channel")}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\nsend.done{id}:\n"
        }
        let conversion: LlvmSlotConversion =
            self.to_slot(element, value, "send")
        return "{retains}{conversion.setup}  %send.ok{id} = call i64 @beans_chan_send(ptr {receiver}, i64 {conversion.value})\n  %send.closed{id} = icmp eq i64 %send.ok{id}, 0\n  br i1 %send.closed{id}, label %send.panic{id}, label %send.done{id}\nsend.panic{id}:\n  call void @beans_panic(ptr {self.string_pointer("send on a closed channel")}, i64 {instruction.line}, i64 {instruction.col})\n  unreachable\nsend.done{id}:\n"
    }

    // a received reference arrives with the queue's count moved to
    // us, so the Option wraps it without another retain; an empty
    // channel hands back a zero slot, which is already the null
    // none and the zeroed inactive payload
    fn emit_channel_recv(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        if receiver_type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs the element type")
            return ""
        }
        let element: HirType = receiver_type.args[0]
        if !self.handle_inner_supported(
             instruction, element, false) {
            return ""
        }
        let option: string =
            self.type_text(instruction.type)
        if option == "" {
            self.fail(
                instruction,
                "LLVM emitter does not support receiving '{render_hir_type(element)}' yet")
            return ""
        }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        let id: int = self.fresh()
        if self.wide_inline_value(element) {
            let llvm: string = self.type_text(element)
            let value_slot: string =
                self.spill_slot(
                    llvm, "channel.recv")
            self.require_declare(
                "beans_chan_recv_typed",
                "i64 @beans_chan_recv_typed(ptr, ptr)")
            return "  store {llvm} zeroinitializer, ptr {value_slot}\n  %recv.found{id} = call i64 @beans_chan_recv_typed(ptr {receiver}, ptr {value_slot})\n  %recv.has{id} = icmp ne i64 %recv.found{id}, 0\n  %recv.value{id} = load {llvm}, ptr {value_slot}\n  %recv.payload{id} = insertvalue {option} poison, {llvm} %recv.value{id}, 1\n  {result} = insertvalue {option} %recv.payload{id}, i1 %recv.has{id}, 0\n"
        }
        let ok_slot: string =
            self.spill_slot("i64", "recv.ok")
        var output: string =
            "  %recv.raw{id} = call i64 @beans_chan_recv(ptr {receiver}, ptr {ok_slot})\n"
        if option == "ptr" {
            return "{output}  {result} = inttoptr i64 %recv.raw{id} to ptr\n"
        }
        let conversion: LlvmSlotConversion =
            self.from_slot(
                element, "%recv.raw{id}",
                "%recv.value{id}", "recv")
        return "{output}  %recv.found{id} = load i64, ptr {ok_slot}\n  %recv.has{id} = icmp ne i64 %recv.found{id}, 0\n{conversion.setup}  %recv.payload{id} = insertvalue {option} poison, {self.type_text(element)} {conversion.value}, 1\n  {result} = insertvalue {option} %recv.payload{id}, i1 %recv.has{id}, 0\n"
    }

    fn emit_channel_close(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        return "  call void @beans_chan_close(ptr {receiver})\n"
    }

    fn emit_channel_async_send_poll(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 3 {
            self.fail(instruction, "LLVM emitter needs a channel, ticket and value")
            return ""
        }
        let receiver_type: HirType =
            self.value_type(function, instruction.operands[0])
        let element: HirType = receiver_type.args[0]
        if !self.handle_inner_supported(instruction, element, false) {
            return ""
        }
        let receiver: string = self.value(
            function, values, instruction.operands[0], instruction)
        let ticket: string = self.value(
            function, values, instruction.operands[1], instruction)
        let value: string = self.value(
            function, values, instruction.operands[2], instruction)
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        if self.wide_inline_value(element) {
            let llvm: string = self.type_text(element)
            let slot: string = self.spill_slot(llvm, "channel.async.send")
            self.require_declare(
                "beans_chan_async_send_typed",
                "i64 @beans_chan_async_send_typed(ptr, i64, ptr)")
            return "  store {llvm} {value}, ptr {slot}\n  {result} = call i64 @beans_chan_async_send_typed(ptr {receiver}, i64 {ticket}, ptr {slot})\n"
        }
        let conversion: LlvmSlotConversion =
            self.to_slot(element, value, "async.send")
        self.require_declare(
            "beans_chan_async_send",
            "i64 @beans_chan_async_send(ptr, i64, i64)")
        return "{conversion.setup}  {result} = call i64 @beans_chan_async_send(ptr {receiver}, i64 {ticket}, i64 {conversion.value})\n"
    }

    fn emit_channel_async_receive_poll(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver_type: HirType =
            self.value_type(function, instruction.operands[0])
        let element: HirType = receiver_type.args[0]
        let receiver: string = self.value(
            function, values, instruction.operands[0], instruction)
        let ticket: string = self.value(
            function, values, instruction.operands[1], instruction)
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        if self.wide_inline_value(element) {
            self.require_declare(
                "beans_chan_async_recv_typed",
                "i64 @beans_chan_async_recv_typed(ptr, i64)")
            return "  {result} = call i64 @beans_chan_async_recv_typed(ptr {receiver}, i64 {ticket})\n"
        }
        self.require_declare(
            "beans_chan_async_recv",
            "i64 @beans_chan_async_recv(ptr, i64)")
        return "  {result} = call i64 @beans_chan_async_recv(ptr {receiver}, i64 {ticket})\n"
    }

    fn emit_channel_async_receive_take(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver_type: HirType =
            self.value_type(function, instruction.operands[0])
        let element: HirType = receiver_type.args[0]
        let option: string = self.type_text(instruction.type)
        let receiver: string = self.value(
            function, values, instruction.operands[0], instruction)
        let ticket: string = self.value(
            function, values, instruction.operands[1], instruction)
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        let id: int = self.fresh()
        if self.wide_inline_value(element) {
            let llvm: string = self.type_text(element)
            let slot: string = self.spill_slot(llvm, "channel.async.take")
            self.require_declare(
                "beans_chan_async_take_typed",
                "i64 @beans_chan_async_take_typed(ptr, i64, ptr)")
            return "  store {llvm} zeroinitializer, ptr {slot}\n  %async.take.ok{id} = call i64 @beans_chan_async_take_typed(ptr {receiver}, i64 {ticket}, ptr {slot})\n  %async.take.value{id} = load {llvm}, ptr {slot}\n  %async.take.payload{id} = insertvalue {option} poison, {llvm} %async.take.value{id}, 1\n  {result} = insertvalue {option} %async.take.payload{id}, i1 true, 0\n"
        }
        self.require_declare(
            "beans_chan_async_take",
            "i64 @beans_chan_async_take(ptr, i64)")
        let conversion: LlvmSlotConversion = self.from_slot(
            element, "%async.take.raw{id}", "%async.take.value{id}",
            "async.take")
        if option == "ptr" {
            return "  %async.take.raw{id} = call i64 @beans_chan_async_take(ptr {receiver}, i64 {ticket})\n  {result} = inttoptr i64 %async.take.raw{id} to ptr\n"
        }
        return "  %async.take.raw{id} = call i64 @beans_chan_async_take(ptr {receiver}, i64 {ticket})\n{conversion.setup}  %async.take.payload{id} = insertvalue {option} poison, {self.type_text(element)} {conversion.value}, 1\n  {result} = insertvalue {option} %async.take.payload{id}, i1 true, 0\n"
    }

    fn emit_channel_async_cancel(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver: string = self.value(
            function, values, instruction.operands[0], instruction)
        let ticket: string = self.value(
            function, values, instruction.operands[1], instruction)
        self.require_declare(
            "beans_chan_async_cancel",
            "i64 @beans_chan_async_cancel(ptr, i64)")
        return "  %async.cancel{self.fresh()} = call i64 @beans_chan_async_cancel(ptr {receiver}, i64 {ticket})\n"
    }

    // ownership of the closure box moves to the thread (MIR marks
    // the operand consumed), and the code pointer rides separately
    fn emit_thread_spawn(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        if instruction.operands.len() != 1 ||
           instruction.type.args.len() != 1 {
            self.fail(
                instruction,
                "LLVM emitter needs one spawn closure")
            return ""
        }
        let payload: HirType = instruction.type.args[0]
        if canonical_hir_name(payload.name) !=
               "unit" &&
           !self.handle_inner_supported(
               instruction, payload, false) {
            return ""
        }
        let closure: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        let thunk: string = self.spawn_thunk(payload)
        if self.wide_inline_value(payload) {
            self.require_declare(
                "beans_thread_spawn_typed",
                "ptr @beans_thread_spawn_typed(ptr, ptr, i64, i64)")
            return "  {result} = call ptr @beans_thread_spawn_typed(ptr @{thunk}, ptr {closure}, i64 {self.type_size(payload)}, i64 {self.pointer_mask_at(payload, 0)})\n"
        }
        return "  {result} = call ptr @beans_thread_spawn(ptr @{thunk}, ptr {closure}, i64 {self.slot_rc_flag(payload)})\n"
    }

    // the runtime invokes the spawned closure as i64(ptr), but the
    // closure's real signature returns the payload type: a double
    // came back in the wrong register class and joined as garbage.
    // Wrap every spawn in a thunk that widens the result into the
    // slot, exactly like production's spawn_thunk. The list named
    // ffi_functions is really the module's extra-function tail.
    fn spawn_thunk(payload: HirType) -> string {
        let symbol: string =
            "spawn.thunk.{self.fresh()}"
        if self.wide_inline_value(payload) {
            let llvm: string = self.type_text(payload)
            self.ffi_functions.push(
                "define void @{symbol}(ptr %env, ptr %out) \{\n  %fn = load ptr, ptr %env\n  %spawn.ret = call {llvm} %fn(ptr %env)\n  store {llvm} %spawn.ret, ptr %out\n  ret void\n\}\n")
            return symbol
        }
        if canonical_hir_name(payload.name) ==
               "unit" {
            self.ffi_functions.push(
                "define i64 @{symbol}(ptr %env) \{\n  %fn = load ptr, ptr %env\n  call void %fn(ptr %env)\n  ret i64 0\n\}\n")
            return symbol
        }
        let llvm: string = self.type_text(payload)
        let conversion: LlvmSlotConversion =
            self.to_slot(
                payload, "%spawn.ret", "spawn")
        self.ffi_functions.push(
            "define i64 @{symbol}(ptr %env) \{\n  %fn = load ptr, ptr %env\n  %spawn.ret = call {llvm} %fn(ptr %env)\n{conversion.setup}  ret i64 {conversion.value}\n\}\n")
        return symbol
    }

    // join moves the thread's result reference to the caller
    fn emit_thread_join(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let id: int = self.fresh()
        if canonical_hir_name(
               instruction.type.name) == "unit" {
            return "  %join.void{id} = call i64 @beans_thread_join(ptr {receiver})\n"
        }
        if !self.handle_inner_supported(
             instruction, instruction.type, false) {
            return ""
        }
        if self.wide_inline_value(
               instruction.type) {
            let llvm: string =
                self.type_text(instruction.type)
            let slot: string =
                self.spill_slot(
                    llvm, "thread.result")
            let result: string =
                "%v{instruction.result}"
            values[instruction.result] = result
            self.require_declare(
                "beans_thread_join_typed",
                "void @beans_thread_join_typed(ptr, ptr, i64)")
            return "  call void @beans_thread_join_typed(ptr {receiver}, ptr {slot}, i64 {self.type_size(instruction.type)})\n  {result} = load {llvm}, ptr {slot}\n"
        }
        // from_slot hands an i64 result back as the raw register
        // itself, so the value binds to whatever it names
        let conversion: LlvmSlotConversion =
            self.from_slot(
                instruction.type, "%join.raw{id}",
                "%v{instruction.result}", "join")
        values[instruction.result] = conversion.value
        return "  %join.raw{id} = call i64 @beans_thread_join(ptr {receiver})\n{conversion.setup}"
    }

    fn emit_thread_async_join_poll(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver: string = self.value(
            function, values, instruction.operands[0], instruction)
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        self.require_declare(
            "beans_thread_async_join_poll",
            "i64 @beans_thread_async_join_poll(ptr)")
        return "  {result} = call i64 @beans_thread_async_join_poll(ptr {receiver})\n"
    }

    fn emit_thread_async_join_claim(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver: string = self.value(
            function, values, instruction.operands[0], instruction)
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        let id: int = self.fresh()
        self.require_declare(
            "beans_thread_async_join_claim",
            "i64 @beans_thread_async_join_claim(ptr)")
        return "  %async.join.claim{id} = call i64 @beans_thread_async_join_claim(ptr {receiver})\n  {result} = icmp ne i64 %async.join.claim{id}, 0\n"
    }

    fn emit_thread_async_join_take(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver_type: HirType = self.value_type(
            function, instruction.operands[0])
        let payload: HirType = receiver_type.args[0]
        let receiver: string = self.value(
            function, values, instruction.operands[0], instruction)
        if canonical_hir_name(payload.name) == "unit" {
            self.require_declare(
                "beans_thread_async_take",
                "i64 @beans_thread_async_take(ptr)")
            return "  %async.join.void{self.fresh()} = call i64 @beans_thread_async_take(ptr {receiver})\n"
        }
        let result: string = "%v{instruction.result}"
        values[instruction.result] = result
        if self.wide_inline_value(payload) {
            let llvm: string = self.type_text(payload)
            let slot: string = self.spill_slot(llvm, "thread.async.take")
            self.require_declare(
                "beans_thread_async_take_typed",
                "i64 @beans_thread_async_take_typed(ptr, ptr, i64)")
            return "  %async.join.take{self.fresh()} = call i64 @beans_thread_async_take_typed(ptr {receiver}, ptr {slot}, i64 {self.type_size(payload)})\n  {result} = load {llvm}, ptr {slot}\n"
        }
        let id: int = self.fresh()
        self.require_declare(
            "beans_thread_async_take",
            "i64 @beans_thread_async_take(ptr)")
        let conversion: LlvmSlotConversion = self.from_slot(
            payload, "%async.join.raw{id}", result, "async.join")
        values[instruction.result] = conversion.value
        return "  %async.join.raw{id} = call i64 @beans_thread_async_take(ptr {receiver})\n{conversion.setup}"
    }

    // maps a folded MemoryOrder tag (MemoryOrder declaration
    // order) onto the LLVM spelling; anything non-literal is a
    // checker bug surfacing here
    fn atomic_ordering(
        instruction: MirInstruction,
        tag: string) -> string {
        if tag == "0" { return "monotonic" }
        if tag == "1" { return "acquire" }
        if tag == "2" { return "release" }
        if tag == "3" { return "acq_rel" }
        if tag == "4" { return "seq_cst" }
        self.fail(
            instruction,
            "LLVM emitter needs a literal memory order")
        return ""
    }

    // Atomic<T>: orders fold into the instruction, which is why
    // the checker requires literals. Atomic<bool> is an i8 cell —
    // LLVM refuses non-byte atomics — widening on the way in and
    // truncating on the way out, like production's emit_atomic_op.
    fn emit_atomic_method(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver_type: HirType =
            self.value_type(
                function, instruction.operands[0])
        let element: HirType = receiver_type.args[0]
        let boolean: bool =
            canonical_hir_name(element.name) == "bool"
        let ty: string =
            if boolean {
                "i8"
            } else {
                self.type_text(element)
            }
        let align: int =
            if boolean {
                1
            } else {
                self.type_size(element)
            }
        let bits: int =
            if boolean {
                8
            } else {
                llvm_integer_bits(element)
            }
        if ty == "" || align <= 0 || bits <= 0 {
            self.fail(
                instruction,
                "LLVM emitter does not support Atomic<{render_hir_type(element)}> yet")
            return ""
        }
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let text: string = instruction.text
        var value_count: int = 1
        if text == "load" || text == "notify_one" ||
           text == "notify_all" {
            value_count = 0
        }
        if text == "compare_exchange" {
            value_count = 2
        }
        if text == "wait_timeout" {
            // expected plus the nanosecond budget
            value_count = 2
        }
        var first_tag: string = "4"
        var second_tag: string = "4"
        let order_base: int = 1 + value_count
        if instruction.operands.len() > order_base {
            first_tag =
                self.value(
                    function, values,
                    instruction.operands[order_base],
                    instruction)
        }
        if instruction.operands.len() > order_base + 1 {
            second_tag =
                self.value(
                    function, values,
                    instruction.operands[
                        order_base + 1],
                    instruction)
        }
        let first_order: string =
            self.atomic_ordering(
                instruction, first_tag)
        let second_order: string =
            self.atomic_ordering(
                instruction, second_tag)
        if first_order == "" || second_order == "" {
            return ""
        }
        let id: int = self.fresh()
        let result: string = "%v{instruction.result}"
        var setup: string = ""
        // widen the first element operand to the cell type
        var operand: string = ""
        if value_count >= 1 && text != "wait_timeout" ||
           text == "wait" || text == "wait_timeout" {
            operand =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            if boolean {
                if operand == "true" ||
                   operand == "1" {
                    operand = "1"
                } else if operand == "false" ||
                          operand == "0" {
                    operand = "0"
                } else {
                    let widened: int = self.fresh()
                    setup =
                        "{setup}  %atomic.widen{widened} = zext i1 {operand} to i8\n"
                    operand = "%atomic.widen{widened}"
                }
            }
        }
        if text == "load" {
            values[instruction.result] = result
            if boolean {
                return "  %atomic.wide{id} = load atomic i8, ptr {receiver} {first_order}, align 1\n  {result} = trunc i8 %atomic.wide{id} to i1\n"
            }
            return "  {result} = load atomic {ty}, ptr {receiver} {first_order}, align {align}\n"
        }
        if text == "store" {
            return "{setup}  store atomic {ty} {operand}, ptr {receiver} {first_order}, align {align}\n"
        }
        var rmw: string = ""
        if text == "exchange" { rmw = "xchg" }
        if text == "fetch_add" { rmw = "add" }
        if text == "fetch_sub" { rmw = "sub" }
        if text == "fetch_and" { rmw = "and" }
        if text == "fetch_or" { rmw = "or" }
        if text == "fetch_xor" { rmw = "xor" }
        if rmw != "" {
            values[instruction.result] = result
            if boolean {
                return "{setup}  %atomic.old{id} = atomicrmw {rmw} ptr {receiver}, i8 {operand} {first_order}, align 1\n  {result} = trunc i8 %atomic.old{id} to i1\n"
            }
            return "{setup}  {result} = atomicrmw {rmw} ptr {receiver}, {ty} {operand} {first_order}, align {align}\n"
        }
        if text == "compare_exchange" {
            var desired: string =
                self.value(
                    function, values,
                    instruction.operands[2],
                    instruction)
            if boolean {
                if desired == "true" ||
                   desired == "1" {
                    desired = "1"
                } else if desired == "false" ||
                          desired == "0" {
                    desired = "0"
                } else {
                    let widened: int = self.fresh()
                    setup =
                        "{setup}  %atomic.widen{widened} = zext i1 {desired} to i8\n"
                    desired = "%atomic.widen{widened}"
                }
            }
            values[instruction.result] = result
            return "{setup}  %atomic.pair{id} = cmpxchg ptr {receiver}, {ty} {operand}, {ty} {desired} {first_order} {second_order}, align {align}\n  {result} = extractvalue \{ {ty}, i1 \} %atomic.pair{id}, 1\n"
        }
        if text == "wait" || text == "wait_timeout" {
            let bounded: bool = text == "wait_timeout"
            // the runtime compares raw cell bits, so the expected
            // value zero-extends; plain digits already are their
            // own zero-extension
            var wide: string = operand
            var digits: bool = operand.len() != 0
            for cursor: int in 0..operand.len() {
                let byte: int = operand.byte_at(cursor)
                if byte < 48 || byte > 57 {
                    digits = false
                }
            }
            if !digits && (boolean || ty != "i64") {
                let extended: int = self.fresh()
                let from: string =
                    if boolean { "i8" } else { ty }
                setup =
                    "{setup}  %atomic.expect{extended} = zext {from} {operand} to i64\n"
                wide = "%atomic.expect{extended}"
            }
            var budget: string = "0"
            if bounded {
                budget =
                    self.value(
                        function, values,
                        instruction.operands[2],
                        instruction)
            }
            let flag: string =
                if bounded { "1" } else { "0" }
            self.require_declare(
                "beans_atomic_wait",
                "i64 @beans_atomic_wait(ptr, i64, i64, i64, i64, i64)")
            var output: string =
                "{setup}  %atomic.wait{id} = call i64 @beans_atomic_wait(ptr {receiver}, i64 {bits}, i64 {wide}, i64 {budget}, i64 {flag}, i64 {first_tag})\n"
            if bounded {
                values[instruction.result] = result
                return "{output}  {result} = icmp ne i64 %atomic.wait{id}, 0\n"
            }
            return output
        }
        if text == "notify_one" ||
           text == "notify_all" {
            let all: string =
                if text == "notify_all" { "1" } else { "0" }
            values[instruction.result] = result
            self.require_declare(
                "beans_atomic_notify",
                "i64 @beans_atomic_notify(ptr, i64, i64)")
            return "  {result} = call i64 @beans_atomic_notify(ptr {receiver}, i64 {bits}, i64 {all})\n"
        }
        self.fail(
            instruction,
            "LLVM emitter does not support builtin method 'Atomic.{text}' yet")
        return ""
    }

    fn emit_atomic_int_method(
        function: MirFunction,
        instruction: MirInstruction,
        values: Map<int, string>) -> string {
        let receiver: string =
            self.value(
                function, values,
                instruction.operands[0], instruction)
        let result: string = "%v{instruction.result}"
        if instruction.text == "load" {
            self.require_declare(
                "beans_atomic_get",
                "i64 @beans_atomic_get(ptr)")
            values[instruction.result] = result
            return "  {result} = call i64 @beans_atomic_get(ptr {receiver})\n"
        }
        if instruction.text == "store" &&
           instruction.operands.len() == 2 {
            let value: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            self.require_declare(
                "beans_atomic_set",
                "void @beans_atomic_set(ptr, i64)")
            return "  call void @beans_atomic_set(ptr {receiver}, i64 {value})\n"
        }
        if instruction.text == "add_and_get" &&
           instruction.operands.len() == 2 {
            let value: string =
                self.value(
                    function, values,
                    instruction.operands[1],
                    instruction)
            self.require_declare(
                "beans_atomic_add",
                "i64 @beans_atomic_add(ptr, i64)")
            values[instruction.result] = result
            return "  {result} = call i64 @beans_atomic_add(ptr {receiver}, i64 {value})\n"
        }
        self.fail(
            instruction,
            "LLVM emitter does not support builtin method 'AtomicInt.{instruction.text}' yet")
        return ""
    }

    // registered defers run newest-first at every normal exit; each
    // site's armed flag keeps an exit that sits above the defer
    // statement (a `?` before it) from running an unregistered one
    fn emit_run_defers(
        function: MirFunction,
        instruction: MirInstruction) -> string {
        var output: string = ""
        let count: int = self.defer_sites.len()
        for step: int in 0..count {
            let site: MirInstruction =
                self.defer_sites[count - 1 - step]
            var cleanup_name: string = ""
            var capture_count: int = 0
            match self.cleanup_functions.get(
                      site.cleanup_id) {
                some(cleanup) => {
                    cleanup_name = cleanup.name
                    capture_count =
                        cleanup.captures.len()
                }
                none => {}
            }
            if cleanup_name == "" ||
               !self.function_symbols.contains_key(
                   cleanup_name) {
                self.fail(
                    instruction,
                    "LLVM emitter cannot find defer cleanup {site.cleanup_id}")
                continue
            }
            if capture_count !=
                   site.capture_locals.len() {
                self.fail(
                    instruction,
                    "LLVM emitter found a defer capture mismatch")
                continue
            }
            var arguments: List<string> = []
            var body: string = ""
            var supported: bool = true
            for source_index: int in
                site.capture_locals {
                if source_index < 0 ||
                   source_index >=
                       function.locals.len() {
                    supported = false
                    continue
                }
                let source: MirLocal =
                    function.locals[source_index]
                if self.cell_local(source) {
                    let cell: int = self.fresh()
                    body =
                        "{body}  %defer.cell{cell} = load ptr, ptr %l{source.id}\n"
                    arguments.push(
                        "ptr %defer.cell{cell}")
                } else {
                    arguments.push(
                        "ptr %l{source.id}")
                }
            }
            if !supported {
                self.fail(
                    instruction,
                    "LLVM emitter does not support this defer capture yet")
                continue
            }
            let id: int = self.fresh()
            output =
                "{output}  %defer.armed{id} = load i1, ptr %defer.flag{site.cleanup_id}\n  br i1 %defer.armed{id}, label %defer.run{id}, label %defer.next{id}\ndefer.run{id}:\n{body}  call void {self.function_symbols[cleanup_name]}({arguments.join(", ")})\n  br label %defer.next{id}\ndefer.next{id}:\n"
        }
        return move output
    }
}
