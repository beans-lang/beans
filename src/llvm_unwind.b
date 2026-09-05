package main

// The controlled unwind, backend half (spec/CONCURRENCY.md).
//
// A panic contained by `brew`/`join`, and a cancel observed at a park, do not
// abandon the fiber's frames: every frame between the failure and the fiber's
// entry runs its defers newest-first and drops what it owns, exactly as a
// return would. This file is what makes that true in the native backend.
//
// The mechanism is the platform's zero-cost exception unwinder — the same one
// C++ and Rust use — and "zero-cost" is the reason it was chosen over a
// registered cleanup chain. Nothing at all is executed on the path where no
// panic happens: a `call` becomes an `invoke`, which is the same instruction
// with a second successor the hardware never visits, and the cleanup lives in
// a block only the unwinder can reach. The cost is module size and an
// optimizer that must respect the extra edges, not an instruction per call.
//
// Three pieces:
//
//  1. Every call that could reach a panic becomes an `invoke` whose exception
//     edge is the function's one cleanup pad. `unwind_chunk` rewrites the
//     emitted text rather than each of the several hundred places that print
//     a `call`, so no site can be forgotten — the property that matters most
//     here, because a forgotten site is a frame that silently keeps leaking.
//  2. `unwind_pad_block` is that pad: a `landingpad ... cleanup`, the same
//     `run_defers` the return path emits, a drop for every owned local, and
//     `resume` to hand the unwind to the caller.
//  3. The fiber's entry thunk (src/llvm_emit_concurrency.b) ends the unwind
//     instead of resuming it, so nothing ever unwinds out of Beans code into
//     the C frames that started the fiber.
//
// Which locals the pad may drop is the whole safety argument. A drop at a
// scope exit knows statically that its local is live; a drop reached from an
// arbitrary instruction does not, so MirLowerer.arm_unwind_flags pins the
// runtime `.live` flag on for every owned local of a program that can unwind,
// and the pad reads it. Under-reading leaks; over-reading double-frees — the
// flag is what makes neither happen.
//
// None of this is emitted unless the program actually brews (MirProgram
// .uses_fibers) on a target whose unwinder we use (TargetDescription
// .supports_unwind). A program that never brews cannot contain a panic, so it
// compiles to exactly the module it compiled to before.

partial class LlvmTextEmitter {
    // Does this module carry cleanup pads at all?
    fn unwind_enabled() -> bool {
        return self.program.uses_fibers &&
               self.program.target.supports_unwind()
    }

    // The personality the pads name. __gcc_personality_v0 is the C
    // cleanup-only personality that ships with the compiler runtime on every
    // target supports_unwind() allows; it never claims a handler, which is
    // exactly right — the runtime drives the walk with _Unwind_ForcedUnwind
    // and the fiber entry is what stops it.
    fn unwind_personality() -> string {
        if !self.unwind_enabled() { return "" }
        self.require_declare(
            "__gcc_personality_v0",
            "i32 @__gcc_personality_v0(...)")
        return " personality ptr @__gcc_personality_v0"
    }

    // Has this function anything to run on the way out? A function that owns
    // nothing and defers nothing needs no pad: the unwinder steps straight
    // through its frame.
    fn unwind_function_needs_pad(
        function: MirFunction) -> bool {
        if !self.unwind_enabled() { return false }
        if function.declaration ||
           function.external { return false }
        if self.defer_sites.len() != 0 { return true }
        // an owned temporary live across a panic point has to be released by
        // the pad even when the frame owns no local at all (issue #44)
        if self.unwind_temp_candidate.len() != 0 {
            return true
        }
        for local: MirLocal in function.locals {
            if self.unwind_drops_local(
                   function, local) {
                return true
            }
            // a captured trivial local owns no value but does own its cell,
            // and release_function_cells is what gives that back
            if self.cell_local(local) { return true }
        }
        return false
    }

    // Is this local one the pad has to consider? The list is the prologue's
    // own: a local the prologue gave no slot has nothing to load, and a local
    // the normal drop path skips must be skipped here too or the two paths
    // would disagree about who owns the reference.
    fn unwind_drops_local(function: MirFunction,
                          local: MirLocal) -> bool {
        if local.ownership != "owned" { return false }
        if local.scalar_replaced { return false }
        if local.stack_closure_id >= 0 { return false }
        if local.parameter &&
           local.passing == "inout" { return false }
        let type: string = self.type_text(local.type)
        if type == "" || type == "void" { return false }
        if self.cell_local(local) {
            // the frame owns the cell; the prologue starts it null and every
            // drop stores null back, so releasing it twice is releasing null
            return true
        }
        if !self.type_has_owned_refs(local.type) {
            return false
        }
        // Everything left must carry the flag. arm_unwind_flags pins it, so
        // a local without one here means the two passes disagree; leaving it
        // undropped leaks, which is the safe half of that disagreement.
        return self.live_flag_slot(local)
    }

    // The cleanup pad itself. Reached only from an exception edge, so its
    // code never runs unless this frame is being unwound. What it runs is the
    // cleanup a return runs, in the order the tree interpreter walks out of
    // the frame (spec/CONCURRENCY.md):
    //
    //  1. what the failing statement was holding — the in-flight temporaries
    //     and the locals of the nested scopes the failure sat inside — newest
    //     first, the way the walker's expression frames and block scopes pop;
    //  2. the defers, newest first, each at most once;
    //  3. the function's own locals, newest first;
    //  4. the value a `return` was carrying when a defer or a deinit on the
    //     way out panicked — the walker hands it back last;
    //  5. the cells of the captured trivial locals.
    //
    // Every unit is guarded by its own flag: a temporary whose reference
    // already changed hands, a local of a scope that exited or was never
    // entered, and a defer that ran (or panicked) all read clear and are
    // skipped, so the pad never asks where the failure landed.
    fn unwind_pad_block(
        function: MirFunction) -> string {
        let id: int = self.fresh()
        let token: string = "%eh.lp{id}"
        var output: string =
            "{self.unwind_pad}:\n  {token} = landingpad \{ ptr, i32 \}\n          cleanup\n"
        output =
            "{output}{self.unwind_pad_inner_units(function)}"
        let position: MirInstruction =
            new MirInstruction(
                "run_defers", -1,
                new HirType("unit"), "", "",
                function.file, function.line,
                function.col)
        output =
            "{output}{self.emit_run_defers(function, position)}"
        var index: int = function.locals.len()
        for index > 0 {
            index -= 1
            let local: MirLocal =
                function.locals[index]
            if local.scope_depth != 0 { continue }
            if !self.unwind_drops_local(
                   function, local) {
                continue
            }
            output =
                "{output}{self.unwind_pad_drop_local(function, local)}"
        }
        output =
            "{output}{self.unwind_pad_return_values(function)}"
        // MIR drops owned locals; a captured *trivial* local still owns its
        // heap cell, and the return path releases those separately. The pad
        // has to release them too or a frame that captured anything leaks its
        // cells. Cells hold null before their init and after their drop, so
        // running this here and at the return cannot double-release.
        output =
            "{output}{self.release_function_cells(function)}"
        return "{output}  resume \{ ptr, i32 \} {token}\n"
    }

    // A local's drop as the pad emits it: 2 is "the flag's value is not
    // known here", which is the truth at an arbitrary failure point and the
    // only shape that reads the flag.
    fn unwind_pad_drop_local(function: MirFunction,
                             local: MirLocal) -> string {
        let drop: MirInstruction =
            new MirInstruction(
                "drop_local", -1,
                new HirType("unit"), local.name, "",
                function.file, function.line,
                function.col)
        drop.local = local.id
        drop.live_state = 2
        return self.emit_drop_local(function, drop)
    }

    // Phase 1: temporaries (other than a return's) and nested-scope locals,
    // by the position of their definition, newest first. The two kinds are
    // ordered together because that is how they were created: a block's
    // local declared after a temporary of the enclosing statement was made
    // is dropped before it, as the walker's block scope pops first.
    fn unwind_pad_inner_units(
        function: MirFunction) -> string {
        var ids: List<int> = []
        var positions: List<int> = []
        var taken: List<bool> = []
        for id: int in self.unwind_temp_order {
            if self.unwind_temp_return.contains_key(id) {
                continue
            }
            ids.push(id)
            positions.push(self.unwind_temp_position[id])
            taken.push(false)
        }
        for local: MirLocal in function.locals {
            if local.scope_depth == 0 { continue }
            if !self.unwind_drops_local(
                   function, local) {
                continue
            }
            // a nested local the emitted code never initializes has a clear
            // flag; it sorts last and its drop is skipped
            ids.push(-(local.id + 1))
            positions.push(
                self.unwind_local_position.get(
                    local.id).or(-1))
            taken.push(false)
        }
        var output: string = ""
        var remaining: int = ids.len()
        for remaining > 0 {
            var best: int = -1
            for candidate: int in 0..ids.len() {
                if taken[candidate] { continue }
                if best < 0 ||
                   positions[candidate] >= positions[best] {
                    best = candidate
                }
            }
            taken[best] = true
            remaining -= 1
            if ids[best] >= 0 {
                output =
                    "{output}{self.unwind_pad_temp_release(function, ids[best])}"
            } else {
                output =
                    "{output}{self.unwind_pad_drop_local(function, function.locals[-ids[best] - 1])}"
            }
        }
        return output
    }

    // Phase 4: the value a return terminator consumes, if one was in flight.
    fn unwind_pad_return_values(
        function: MirFunction) -> string {
        var output: string = ""
        var index: int = self.unwind_temp_order.len()
        for index > 0 {
            index -= 1
            let id: int = self.unwind_temp_order[index]
            if !self.unwind_temp_return.contains_key(id) {
                continue
            }
            output =
                "{output}{self.unwind_pad_temp_release(function, id)}"
        }
        return output
    }

    // One temporary's guarded release: flagged means the frame still owns
    // the reference. The flag clears before the release, as a drop's does.
    fn unwind_pad_temp_release(function: MirFunction,
                               id: int) -> string {
        let slot: string = self.unwind_temp_slot[id]
        let type: string =
            self.unwind_temp_llvm_type(function, id)
        let temporary: int = self.fresh()
        let release_block: int = self.fresh()
        let merge_block: int = self.fresh()
        let held: string = "%eh.tmp{temporary}"
        var release: string = ""
        if self.iterator_kind.contains_key(id) {
            release =
                "  call void @beans_release(ptr {held})\n"
        } else {
            release =
                self.emit_arc_value(
                    self.value_type(function, id),
                    held, false)
        }
        return "  %eh.tmp.live{temporary} = load i1, ptr {slot}.live\n  br i1 %eh.tmp.live{temporary}, label %eh.tmp.release{release_block}, label %eh.tmp.next{merge_block}\neh.tmp.release{release_block}:\n  {held} = load {type}, ptr {slot}\n  store i1 false, ptr {slot}.live\n{self.unwind_pad_unbuilt_disarm(id, held)}{release}  br label %eh.tmp.next{merge_block}\neh.tmp.next{merge_block}:\n"
    }

    // An unwind out of a `new`'s own construction takes the object's
    // deinit off it before releasing it: the initializer did not return, so
    // its `deinit` body would read fields the initializer never reached
    // (#120). RC_FIN is rc-word bit 61, the flag beans_release tests before
    // it dispatches a deinit, and clearing it is what makes this one death
    // silent while still releasing every field that WAS assigned.
    //
    // Two guards, and both are load-bearing. The construction flag is true
    // only between the allocation and the initializer's return, so an
    // unwind that merely passes a finished object still standing in its
    // temporary releases it with its deinit intact. And the count must be
    // one: an initializer may hand `self` out once every field is assigned,
    // and that object survives this release — disarming it there would
    // silence a deinit the surviving owner is entitled to. A count of one
    // means this frame holds the only reference and the object dies here.
    //
    // The rc word is read and written plainly, not atomically, which is
    // what beans_do_deinit does at the same bit for the same reason. It is
    // sound because an object under construction cannot be reachable from
    // another thread: reaching one needs Send, Send classes are `unique`
    // and therefore move-only, and `self` inside an initializer is a
    // borrowed binding the checker refuses to move or to capture by move.
    // So no other thread can hold this object while this runs.
    fn unwind_pad_unbuilt_disarm(id: int,
                                 held: string) -> string {
        match self.unwind_construct_flag.get(id) {
            some(flag) => {
                let mark: int = self.fresh()
                return "  %eh.new.building{mark} = load i1, ptr {flag}\n  br i1 %eh.new.building{mark}, label %eh.new.check{mark}, label %eh.new.kept{mark}\neh.new.check{mark}:\n  %eh.new.rc.addr{mark} = getelementptr i8, ptr {held}, i64 -16\n  %eh.new.rc{mark} = load i64, ptr %eh.new.rc.addr{mark}\n  %eh.new.count{mark} = and i64 %eh.new.rc{mark}, 281474976710655\n  %eh.new.sole{mark} = icmp eq i64 %eh.new.count{mark}, 1\n  br i1 %eh.new.sole{mark}, label %eh.new.disarm{mark}, label %eh.new.kept{mark}\neh.new.disarm{mark}:\n  %eh.new.plain{mark} = and i64 %eh.new.rc{mark}, -2305843009213693953\n  store i64 %eh.new.plain{mark}, ptr %eh.new.rc.addr{mark}\n  br label %eh.new.kept{mark}\neh.new.kept{mark}:\n"
            }
            none => { return "" }
        }
    }

    // The slot the pad reads to tell "this object is still being built"
    // from "this object is finished and merely still in its temporary".
    // Made on the first mention, like the temporary's own slot.
    fn unwind_construct_slot(id: int) -> string {
        match self.unwind_construct_flag.get(id) {
            some(flag) => { return flag }
            none => {}
        }
        let flag: string = "%eh.new.built.v{id}"
        self.function_allocas.push(
            "  {flag} = alloca i1\n  store i1 false, ptr {flag}\n")
        self.unwind_construct_flag[id] = flag
        return flag
    }

    // emit_new's two stores around the construction. `open` arms the flag
    // with the object allocated and nothing assigned yet; `close` disarms it
    // where the initializer returned. A `new` with no initializer at all is
    // built the moment its defaults are in, and closes right there.
    //
    // `deinit` is the same condition the FIN bit is set under: a class chain
    // with no deinit never has the bit, so there would be nothing for the
    // pad to take off it and the flag would only cost the IR.
    fn unwind_construct_open(function: MirFunction,
                             instruction: MirInstruction,
                             heap: bool, deinit: bool) -> string {
        if !heap || !deinit { return "" }
        if !self.unwind_temp_wanted(
               function, instruction.result) {
            return ""
        }
        return "  store i1 true, ptr {self.unwind_construct_slot(instruction.result)}\n"
    }

    fn unwind_construct_close(function: MirFunction,
                              instruction: MirInstruction,
                              heap: bool) -> string {
        if !heap { return "" }
        if !self.unwind_construct_flag.contains_key(
               instruction.result) {
            return ""
        }
        return "  store i1 false, ptr {self.unwind_construct_flag[instruction.result]}\n"
    }

    // ---- in-flight owned temporaries ----------------------------------
    //
    // A MIR value that holds an owned reference — the result of `new`, a
    // call, a literal, a retain, the collection an iterator took — and is
    // still live when a later instruction panics belongs to no local: the
    // plan releases it after its last use, and a pad that only knows locals
    // leaks it. The interpreter releases such a value as its expression
    // frames unwind, so a native build has to as well, in the same order.
    //
    // The rule: every such value is stored beside the locals at its
    // definition, with a flag; the flag clears when the reference changes
    // hands — at the release the plan scheduled, or when a consumer takes
    // it — and the pad releases whatever is still flagged.
    //
    // When the hand-off happens is what keeps a value from being released
    // twice. A callee that is emitted Beans code owns a moved argument from
    // its entry (its own frame drops it if it panics), and a store into a
    // local or a field is the transfer itself — those clear the flag before
    // the instruction. A runtime call that can panic does so before it takes
    // the value (argument validation), so its consumer clears after: a panic
    // in between leaves the value flagged and the pad releases it, as the
    // interpreter does. A list index assignment, the one inline consumer
    // that checks before it stores, clears between its store and the release
    // of the element it replaced.

    // A class object exists from its allocation, so its own init is the
    // first call it is live across (a panic inside init must release the
    // half-built object, fields and all). Handle types are runtime calls.
    fn unwind_class_new(instruction: MirInstruction) -> bool {
        if instruction.op != "new" { return false }
        match self.declaration_for(instruction.type) {
            some(declaration) => {
                return declaration.kind == "class"
            }
            none => { return false }
        }
    }

    // Does this consumer own its consumed operands from its entry — so the
    // temporary's flag clears before the instruction — or does it validate
    // before it takes them, so the flag clears after?
    //
    // The line is drawn by what can go wrong between the two points. A
    // consumer that takes the value and can then panic, or run Beans code
    // that panics, must clear before: a flag still set past the take would
    // have the pad release a value the consumer already owns — a double
    // release. A consumer that can refuse the value with a panic before it
    // takes it must clear after: a flag already clear at that panic would
    // leak the value the interpreter releases. Clearing before is the safe
    // half, so it is the default; "after" is an allowlist of entries each
    // audited to take last and never fail past the take, and a runtime
    // method that consumes a reference and is not on the list gets the
    // default until someone audits it and adds it here with its line.
    fn unwind_transfer_at_entry(
        function: MirFunction,
        instruction: MirInstruction) -> bool {
        return !self.unwind_validates_before_take(
            function, instruction)
    }

    // The allowlist. Every entry names the audit that put it here.
    fn unwind_validates_before_take(
        function: MirFunction,
        instruction: MirInstruction) -> bool {
        let op: string = instruction.op
        if op == "cast" {
            // a checked cast refuses before it produces (inline)
            return true
        }
        if op == "unwrap" || op == "propagate" ||
           op == "iterate_init" {
            // cannot panic
            return true
        }
        if op == "assign" &&
           instruction.text.starts_with("index::") {
            // list[i] = v, array[i] = v: inline, bounds first; the store
            // clears the flag itself, before the old element's release.
            // map[k] = v is NOT on this list: the store must stand when
            // the old value's deinit panics (the interpreter's rule), so
            // the runtime stores first and releases the old value last —
            // a panic after the take. The operands ride the leak-safe
            // clear-before default instead; only a growth failure before
            // the store can strand them, abandoned like the panicking
            // object itself.
            let target: string =
                canonical_hir_name(
                    self.value_type(
                        function,
                        instruction.operands[0]).name)
            return target != "Map" && target != "OrderedMap"
        }
        if op != "builtin_method" ||
           instruction.operands.len() == 0 {
            return false
        }
        let receiver: string =
            canonical_hir_name(
                self.value_type(
                    function,
                    instruction.operands[0]).name)
        let method: string = instruction.text
        if receiver == "List" {
            // beans_list_push / beans_list_insert(_typed): bounds check and
            // growth (with its out-of-memory panic) first, store last
            return method == "push" || method == "insert"
        }
        if receiver == "Map" || receiver == "OrderedMap" {
            // Every map entry point owns the key and the value from the
            // call, so all of them are clear-before. `set` because it stores
            // first (map[k] = v above). `insert` because a declined insert
            // releases both itself, and that release runs a deinit: with the
            // flag still set past it, the pad released the value the entry
            // had already destroyed — invisible only while a panicking
            // deinit left its object abandoned, and a use-after-free the
            // moment that object's shell started coming back (issue #81).
            // The entry is complete about it in exchange: whatever it does
            // not store, it releases, on the decline path and on the growth
            // failure alike.
            return false
        }
        if receiver == "Channel" {
            // beans_chan_send declines a closed channel without taking the
            // value ("caller also still owns v"); the inline panic follows
            return method == "send"
        }
        if receiver == "Box" {
            // beans_box_set follows map[k] = v above: the store stands when
            // the old value's deinit panics (issue #79, the interpreter's
            // rule), so the runtime stores first and releases the old value
            // last — a panic after the take, which is clear-before. It used
            // to release first, and a flag still set past that store had the
            // pad release a value the box already owned.
            return false
        }
        if receiver == "Arena" {
            // beans_arena_put(_typed): growth (out-of-memory, capacity)
            // first, store last
            return method == "add" || method == "put"
        }
        return false
    }

    // Can this instruction start an unwind? Its own effects say so for the
    // calls, indexes, casts and `?`; a drop, an assignment and a release run
    // a deinit, and a deinit can panic.
    fn unwind_can_panic(instruction: MirInstruction) -> bool {
        return instruction.effects.contains("panic") ||
               instruction.op == "drop_local" ||
               instruction.op == "assign" ||
               instruction.op == "run_defers" ||
               instruction.releases.len() != 0
    }

    fn unwind_consumes(instruction: MirInstruction,
                       id: int) -> bool {
        for index: int in 0..instruction.consumes.len() {
            if instruction.consumes[index] &&
               index < instruction.operands.len() &&
               instruction.operands[index] == id {
                return true
            }
        }
        return false
    }

    fn unwind_returned_elsewhere(function: MirFunction,
                                 id: int) -> bool {
        for block: MirBlock in function.blocks {
            let terminator: MirTerminator = block.terminator
            if terminator.kind == "return" &&
               terminator.consumes_value &&
               terminator.value == id {
                return true
            }
        }
        return false
    }

    // Which values are candidates, from MIR alone and before the body is
    // emitted, because whether the frame gets a pad depends on it. A value
    // is a candidate when an instruction that can panic sits between its
    // definition and its death, when its consumer can panic before taking
    // it, or — conservatively — when it leaves its block at all. Naming a
    // value that turns out never to need its slot costs a store or two.
    fn unwind_scan_temps(function: MirFunction) {
        for block: MirBlock in function.blocks {
            if !block.reachable { continue }
            for index: int in 0..block.instructions.len() {
                let definition: MirInstruction =
                    block.instructions[index]
                if definition.removed ||
                   definition.result < 0 {
                    continue
                }
                let id: int = definition.result
                var unit: bool = false
                if definition.op == "iterate_init" {
                    unit =
                        definition.consumes.len() != 0 &&
                        definition.consumes[0]
                } else if self.value_ownership(function, id) ==
                              "owned" &&
                          self.type_has_owned_refs(
                              self.value_type(function, id)) {
                    unit = true
                }
                if !unit { continue }
                var candidate: bool =
                    self.unwind_class_new(definition)
                var crossed: bool = false
                var dead: bool = false
                var scan: int = index + 1
                for scan < block.instructions.len() && !dead {
                    let step: MirInstruction =
                        block.instructions[scan]
                    scan += 1
                    if step.removed { continue }
                    if self.unwind_consumes(step, id) {
                        if crossed ||
                           (!self.unwind_transfer_at_entry(function, step) &&
                            self.unwind_can_panic(step)) {
                            candidate = true
                        }
                        dead = true
                    } else if step.releases.contains(id) {
                        // released after the instruction: live through it,
                        // and through the releases listed ahead of it
                        if crossed ||
                           self.unwind_can_panic(step) {
                            candidate = true
                        }
                        dead = true
                    } else if self.unwind_can_panic(step) {
                        crossed = true
                    }
                }
                if !dead {
                    let terminator: MirTerminator =
                        block.terminator
                    if terminator.releases.contains(id) {
                        if crossed { candidate = true }
                    } else if terminator.kind == "return" &&
                              terminator.consumes_value &&
                              terminator.value == id {
                        if crossed { candidate = true }
                        self.unwind_temp_return[id] = true
                    } else {
                        candidate = true
                        if self.unwind_returned_elsewhere(
                               function, id) {
                            self.unwind_temp_return[id] = true
                        }
                    }
                }
                if candidate {
                    self.unwind_temp_candidate[id] = true
                }
            }
        }
    }

    fn unwind_temp_llvm_type(function: MirFunction,
                             id: int) -> string {
        let type: HirType = self.value_type(function, id)
        if canonical_hir_name(type.name) == "iterator" {
            return "ptr"
        }
        return self.type_text(type)
    }

    // The slot of a candidate, made on first mention. A clear can be
    // emitted before the definition — the plan releases a value on the edge
    // of a block that precedes its own — and the flag starts clear, so that
    // order is a harmless store.
    fn unwind_temp_slot_of(function: MirFunction,
                           id: int) -> string {
        match self.unwind_temp_slot.get(id) {
            some(slot) => { return slot }
            none => {}
        }
        let slot: string = "%eh.tmp.v{id}"
        let type: HirType = self.value_type(function, id)
        var alignment: string = ""
        if canonical_hir_name(type.name) != "iterator" {
            alignment =
                self.explicit_alloca_alignment(type)
        }
        self.function_allocas.push(
            "  {slot} = alloca {self.unwind_temp_llvm_type(function, id)}{alignment}\n  {slot}.live = alloca i1\n  store i1 false, ptr {slot}.live\n")
        self.unwind_temp_slot[id] = slot
        return slot
    }

    // Is this candidate one the pad may release? The same skips
    // emit_release applies: a value that is a scalar-replaced local's alias,
    // an inout address or a layout selector owns no count, and an iterator
    // owns its collection only when it took one.
    fn unwind_temp_wanted(function: MirFunction,
                          id: int) -> bool {
        if self.unwind_pad == "" { return false }
        if !self.unwind_temp_candidate.contains_key(id) {
            return false
        }
        if self.inout_addresses.contains_key(id) {
            return false
        }
        if self.selector_texts.contains_key(id) {
            return false
        }
        match self.borrowed_local_of.get(id) {
            some(local_id) => {
                if local_id >= 0 &&
                   local_id < function.locals.len() &&
                   function.locals[
                       local_id].scalar_replaced {
                    return false
                }
            }
            none => {}
        }
        if self.iterator_kind.contains_key(id) {
            return self.iterator_collection.contains_key(id) &&
                   !self.iterator_collection_borrowed.contains_key(id)
        }
        return true
    }

    // The definition: the value goes into its slot and the flag comes on.
    fn unwind_temp_define(function: MirFunction,
                          instruction: MirInstruction,
                          values: Map<int, string>) -> string {
        let id: int = instruction.result
        if id < 0 { return "" }
        if self.unwind_temp_defined.contains_key(id) {
            return ""
        }
        if !self.unwind_temp_wanted(function, id) {
            return ""
        }
        var text: string = ""
        if self.iterator_kind.contains_key(id) {
            text = self.iterator_collection[id]
        } else {
            match values.get(id) {
                some(found) => { text = found }
                none => {
                    // A wanted candidate with no rendered value would get
                    // no slot and no flag, and the pad would silently leak
                    // it — the same silent skip unwind_close exists to
                    // forbid on the clear side. Refuse the build instead.
                    self.fail_function(
                        function,
                        "LLVM emitter has no value text for temporary v{id}, so its unwind slot cannot be defined")
                    return ""
                }
            }
        }
        return self.unwind_temp_define_value(
            function, id, text)
    }

    fn unwind_temp_define_value(function: MirFunction,
                                id: int,
                                text: string) -> string {
        let slot: string =
            self.unwind_temp_slot_of(function, id)
        self.unwind_temp_defined[id] = true
        self.unwind_temp_order.push(id)
        self.unwind_temp_position[id] =
            self.unwind_position
        return "  store {self.unwind_temp_llvm_type(function, id)} {text}, ptr {slot}\n  store i1 true, ptr {slot}.live\n"
    }

    // emit_new's half of the rule: the fresh object goes into its slot
    // before its init runs, so a panic inside init releases it — deinit and
    // fields — the way the interpreter does. A stack object owns no count.
    fn unwind_temp_define_new(function: MirFunction,
                              instruction: MirInstruction,
                              result: string,
                              heap: bool) -> string {
        if !heap { return "" }
        if !self.unwind_temp_wanted(
               function, instruction.result) {
            return ""
        }
        return self.unwind_temp_define_value(
            function, instruction.result, result)
    }

    // The hand-off: the frame no longer owns the reference.
    fn unwind_temp_clear(function: MirFunction,
                         id: int) -> string {
        if self.unwind_pad == "" { return "" }
        if !self.unwind_temp_candidate.contains_key(id) {
            return ""
        }
        let slot: string =
            self.unwind_temp_slot_of(function, id)
        self.unwind_temp_cleared[id] = true
        return "  store i1 false, ptr {slot}.live\n"
    }

    // The consumed operands of one instruction, cleared before it when it
    // owns them from its entry and after it otherwise. A phi consumes on
    // the edge that feeds it, which edge_phi_stores clears.
    fn unwind_temp_consume(function: MirFunction,
                           instruction: MirInstruction,
                           before: bool) -> string {
        if self.unwind_pad == "" { return "" }
        if instruction.op == "phi" { return "" }
        if self.unwind_transfer_at_entry(function, instruction) !=
           before {
            return ""
        }
        var output: string = ""
        for index: int in 0..instruction.consumes.len() {
            if !instruction.consumes[index] ||
               index >= instruction.operands.len() {
                continue
            }
            output =
                "{output}{self.unwind_temp_clear(function, instruction.operands[index])}"
        }
        return output
    }

    // Where a nested-scope local was initialized, so phase 1 can order it
    // among the temporaries by creation.
    fn unwind_note_local_init(function: MirFunction,
                              instruction: MirInstruction) {
        if self.unwind_pad == "" { return }
        if instruction.op != "local_init" &&
           instruction.op != "pattern_bind" {
            return
        }
        let local: int = instruction.local
        if local < 0 || local >= function.locals.len() {
            return
        }
        if function.locals[local].scope_depth == 0 {
            return
        }
        if self.unwind_local_position.contains_key(local) {
            return
        }
        self.unwind_local_position[local] =
            self.unwind_position
    }

    // After the body: every temporary that was given a slot has to have had
    // its hand-off emitted somewhere, or the pad could release it twice or
    // never. The plan guarantees each owned value is consumed or released;
    // this checks the emitter honoured that at a site the clear reaches.
    fn unwind_close(function: MirFunction) {
        for id: int in self.unwind_temp_order {
            if self.unwind_temp_cleared.contains_key(id) {
                continue
            }
            self.fail_function(
                function,
                "LLVM emitter cannot find where temporary v{id} changes hands, so its unwind cleanup is unsafe")
        }
    }

    // Rewrites one emitted chunk so every call in it can be unwound through.
    //
    // Working on the text is deliberate. The emitter prints calls from more
    // than five hundred places and has no CFG to walk; rewriting each place
    // would be a list that goes stale the first time someone adds a call, and
    // a call that stayed a `call` is a frame whose cleanup the unwinder skips
    // without saying so. One pass over the text cannot miss one.
    fn unwind_chunk(text: string) -> string {
        if self.unwind_pad == "" { return text }
        if text == "" { return text }
        var out: List<string> = []
        var start: int = 0
        for start < text.len() {
            let end: int = llvm_line_end(text, start)
            let line: string = text.slice(start, end)
            out.push(self.unwind_line(line))
            if end < text.len() { out.push("\n") }
            start = end + 1
        }
        return out.join("")
    }

    fn unwind_line(line: string) -> string {
        var head: int = 0
        for head < line.len() &&
            (line.byte_at(head) == 32 ||
             line.byte_at(head) == 9) {
            head += 1
        }
        if head >= line.len() { return line }
        // A label opens a new block: remember which one, so a phi below can
        // be told the predecessor's real tail after a split.
        if line.byte_at(line.len() - 1) == 58 &&
           head == 0 {
            self.unwind_block =
                line.slice(0, line.len() - 1)
            return line
        }
        let body: string =
            line.slice(head, line.len())
        if body.starts_with("phi ") ||
           body.contains(" = phi ") {
            return self.unwind_phi(line)
        }
        var keyword: int = -1
        if body.starts_with("call ") {
            keyword = head
        } else {
            match line.find(" = call ") {
                some(at) => { keyword = at + 3 }
                none => {}
            }
        }
        if keyword < 0 { return line }
        // An intrinsic is not a call the unwinder can pass through, and none
        // of them reaches a panic. Inline assembly is not a call at all.
        if line.contains("@llvm.") ||
           line.contains(" asm ") {
            return line
        }
        // Metadata has to stay last on the instruction, so the successor
        // clause goes in front of it.
        var main: string = line
        var suffix: string = ""
        match line.rfind(", !dbg ") {
            some(at) => {
                main = line.slice(0, at)
                suffix = line.slice(at, line.len())
            }
            none => {}
        }
        let id: int = self.fresh()
        let resume: string = "eh.cont{id}"
        self.unwind_used = true
        self.unwind_alias_from.push(
            self.unwind_block)
        self.unwind_alias_to.push(resume)
        self.unwind_block = resume
        let rewritten: string =
            "{main.slice(0, keyword)}invoke{main.slice(keyword + 4, main.len())}"
        return "{rewritten} to label %{resume} unwind label %{self.unwind_pad}{suffix}\n{resume}:"
    }

    // A phi names the block control came from. Splitting a block at a call
    // moves that name to the tail the invoke's normal edge opens, and the
    // phi has to say so or the module does not verify.
    fn unwind_phi(line: string) -> string {
        var text: string = line
        for index: int in
            0..self.unwind_alias_from.len() {
            let from: string =
                self.unwind_alias_from[index]
            if from == "" { continue }
            text =
                text.replace(
                    ", %{from} ]",
                    ", %{self.unwind_alias_to[index]} ]")
        }
        return text
    }

    // Opens a function's unwind state. Called before its body is emitted,
    // because the body's rewrite has to know the pad's name.
    fn unwind_open(function: MirFunction) {
        self.unwind_pad = ""
        self.unwind_used = false
        self.unwind_block = ""
        self.unwind_alias_from = []
        self.unwind_alias_to = []
        self.unwind_temp_candidate = {}
        self.unwind_temp_return = {}
        self.unwind_temp_slot = {}
        self.unwind_temp_defined = {}
        self.unwind_temp_cleared = {}
        self.unwind_temp_order = []
        self.unwind_temp_position = {}
        self.unwind_local_position = {}
        self.unwind_construct_flag = {}
        self.unwind_position = 0
        if !self.unwind_enabled() ||
           function.declaration || function.external {
            return
        }
        self.unwind_scan_temps(function)
        if !self.unwind_function_needs_pad(function) {
            return
        }
        self.unwind_pad = "eh.pad{self.fresh()}"
    }
}
