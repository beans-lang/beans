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
    // code never runs unless this frame is being unwound.
    fn unwind_pad_block(
        function: MirFunction) -> string {
        let id: int = self.fresh()
        let token: string = "%eh.lp{id}"
        var output: string =
            "{self.unwind_pad}:\n  {token} = landingpad \{ ptr, i32 \}\n          cleanup\n"
        // The same defers the return path runs, in the same order, guarded by
        // the same armed flags: a defer whose registration the panic never
        // reached has a clear flag and does not run.
        let position: MirInstruction =
            new MirInstruction(
                "run_defers", -1,
                new HirType("unit"), "", "",
                function.file, function.line,
                function.col)
        output =
            "{output}{self.emit_run_defers(function, position)}"
        // Locals newest-first, which is reverse declaration order across
        // every scope — the order emit_local_drops_from produces at a return.
        // A local of a scope that already exited has a clear flag (its drop
        // stored one) and a local of a scope the panic never entered has
        // never had one set, so both are skipped here without asking where
        // the failure landed.
        var index: int = function.locals.len()
        for index > 0 {
            index -= 1
            let local: MirLocal =
                function.locals[index]
            if !self.unwind_drops_local(
                   function, local) {
                continue
            }
            let drop: MirInstruction =
                new MirInstruction(
                    "drop_local", -1,
                    new HirType("unit"), local.name, "",
                    function.file, function.line,
                    function.col)
            drop.local = local.id
            // 2 is "the flag's value is not known here", which is the truth
            // at an arbitrary failure point and the only shape that reads it.
            drop.live_state = 2
            output =
                "{output}{self.emit_drop_local(function, drop)}"
        }
        // MIR drops owned locals; a captured *trivial* local still owns its
        // heap cell, and the return path releases those separately. The pad
        // has to release them too or a frame that captured anything leaks its
        // cells. Cells hold null before their init and after their drop, so
        // running this here and at the return cannot double-release.
        output =
            "{output}{self.release_function_cells(function)}"
        return "{output}  resume \{ ptr, i32 \} {token}\n"
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
        if !self.unwind_function_needs_pad(function) {
            return
        }
        self.unwind_pad = "eh.pad{self.fresh()}"
    }
}
