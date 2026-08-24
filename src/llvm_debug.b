package main

// Beans source line tables for native debug builds.
//
// A `--debug` build asks for a binary a person can stop inside, so the
// emitter writes LLVM's debug metadata beside the instructions it already
// writes: one compile unit, one file per source, one subprogram per emitted
// function and one location per distinct source position. Clang turns that
// into a DWARF line table — CodeView when the target is MSVC — and `lldb`,
// `gdb` and the editors that drive them can then stop on `main.b:12`, walk a
// stack that names Beans functions, and step a line at a time.
//
// Every other build writes none of this and pays nothing for it. `debug_info`
// is false, `debug_scope` stays -1, and every helper below returns an empty
// string that interpolates away.
//
// Three rules the textual format enforces, each of which costs a build to
// rediscover:
//
//   1. `target triple` must come before any named metadata. Putting
//      `!llvm.dbg.cu` above it stops Clang with "expected top-level entity"
//      pointed at the triple line, which says nothing about metadata.
//   2. A call inside a function that carries a `DISubprogram` must carry a
//      `!dbg` of its own or the verifier rejects the module. That is why
//      every emitted line is decorated rather than the first line of each
//      statement, and why a function with no location gets no subprogram
//      instead of a partial one.
//   3. A `DISubprogram` must not carry `linkageName`. With one, `lldb` labels
//      every frame with the mangled symbol and `b main.helper` answers "no
//      locations (pending)"; without one the frame reads `main.helper` and
//      the breakpoint resolves.

partial class LlvmTextEmitter {
    // One metadata node, shared by every reference with the same text. The
    // line table is mostly repetition — one location per statement, reused by
    // every instruction the statement lowered to — so interning is what keeps
    // the metadata block a fraction of the module rather than a copy of it.
    fn debug_node(text: string) -> int {
        match self.debug_meta_ids.get(text) {
            some(found) => { return found }
            none => {}
        }
        let id: int = self.debug_meta.len()
        self.debug_meta.push(text)
        self.debug_meta_ids[text] = id
        return id
    }

    // A node LLVM gives its own identity to. Two subprograms that happen to
    // print the same text are still two functions, so these never intern.
    fn debug_distinct_node(text: string) -> int {
        let id: int = self.debug_meta.len()
        self.debug_meta.push(text)
        return id
    }

    // The compile unit, its file, and the one signature type every subprogram
    // shares. Called once, before any function is emitted, because a
    // subprogram cannot name a unit that has no id yet.
    //
    // The unit's file is the entry point's, the way a C compile unit is named
    // after its .c file: everything else in the program reaches the debugger
    // through its own DIFile, which is how a header's code is described too.
    fn open_debug_unit() {
        if !self.debug_info { return }
        self.debug_directory = Dir.current()
        var main_file: string = ""
        for function: MirFunction in self.program.functions {
            if function.declaration || function.external { continue }
            if function.file == "" { continue }
            if function.name == self.program.entry_symbol {
                main_file = function.file
            }
            if main_file == "" { main_file = function.file }
        }
        self.debug_main_file = main_file
        let file: int = self.debug_file(main_file)
        // DW_LANG_C99 is a deliberate stand-in. Beans has no DWARF language
        // code of its own, and an unknown one leaves both debuggers guessing;
        // C99 selects a plugin that reads this line table, these frames and
        // these locals correctly. The one visible consequence is that `p`
        // parses expressions as C — `frame variable` is unaffected.
        self.debug_unit = self.debug_distinct_node(
            "distinct !DICompileUnit(language: DW_LANG_C99, file: !{file}, producer: \"beansc {compiler_version()}\", isOptimized: false, runtimeVersion: 0, emissionKind: FullDebug, splitDebugInlining: false)")
        // Every Beans signature prints as one unspecified-parameter type.
        // A real signature needs the type mapper that locals will need, and
        // a line table does not: the debugger takes the frame's name, file
        // and line from the subprogram and its parameters from nothing.
        self.debug_subroutine_type = self.debug_node(
            "!DISubroutineType(types: !{self.debug_node("!\{null\}")})")
    }

    // The DIFile for one source path, made once per path.
    //
    // The filename is recorded exactly as the command line gave it and the
    // directory is the build's own, which is what Clang does: a debugger
    // joins the two, so a relative build stays resolvable and an absolute one
    // is already resolved. Editors need this — a breakpoint set in VS Code or
    // Zed carries an absolute path and has to match what the binary says.
    fn debug_file(file: string) -> int {
        var key: string = file
        if key == "" { key = self.debug_main_file }
        if key == "" { key = "<beans>" }
        match self.debug_file_ids.get(key) {
            some(found) => { return found }
            none => {}
        }
        let id: int = self.debug_node(
            "!DIFile(filename: \"{llvm_metadata_text(key)}\", directory: \"{llvm_metadata_text(self.debug_directory)}\")")
        self.debug_file_ids[key] = id
        return id
    }

    // The subprogram for one emitted function, or -1 for a function the
    // debugger is not told about.
    //
    // A function with no source position gets -1 and, with it, no `!dbg` on
    // any of its lines. That is the whole rule for compiler-made bodies —
    // reflection thunks, ffi wrappers, show and sort helpers — and it keeps
    // them consistent with rule 2 above without naming any of them here.
    fn debug_subprogram(function: MirFunction) -> int {
        if !self.debug_info { return -1 }
        if function.file == "" { return -1 }
        if !self.function_symbols.contains_key(function.name) {
            return -1
        }
        let file: int = self.debug_file(function.file)
        var line: int = function.line
        if line < 0 { line = 0 }
        return self.debug_distinct_node(
            "distinct !DISubprogram(name: \"{llvm_metadata_text(display_symbol(function.name))}\", scope: !{file}, file: !{file}, line: {line}, type: !{self.debug_subroutine_type}, scopeLine: {line}, spFlags: DISPFlagDefinition, unit: !{self.debug_unit})")
    }

    // Enters a function: every location made from here on hangs off this
    // subprogram until the next call.
    fn open_debug_scope(function: MirFunction, subprogram: int) {
        self.debug_scope = subprogram
        self.debug_scope_file = function.file
        self.debug_scope_line = function.line
        if self.debug_scope_line < 0 { self.debug_scope_line = 0 }
    }

    fn close_debug_scope() {
        self.debug_scope = -1
        self.debug_scope_file = ""
        self.debug_scope_line = 0
    }

    // The ` , !dbg !N` an instruction line ends with, or "" when this build
    // writes no line table and when the function has no subprogram.
    //
    // A position the lowering never filled in falls back to the function's
    // own line rather than to line 0. Line 0 is DWARF's "no source here", and
    // a debugger steps straight through it; the declaration line is wrong by
    // a few lines at worst and always stops somewhere a person can see.
    fn debug_location(file: string, line: int, col: int) -> string {
        if !self.debug_info { return "" }
        if self.debug_scope < 0 { return "" }
        var use_file: string = file
        var use_line: int = line
        var use_col: int = col
        if use_file == "" || use_line <= 0 {
            use_file = self.debug_scope_file
            use_line = self.debug_scope_line
            use_col = 1
        }
        if use_col < 0 { use_col = 0 }
        var scope: int = self.debug_scope
        if use_file != self.debug_scope_file {
            // A location must resolve to the subprogram it sits inside, so a
            // position from another file cannot simply point at that file's
            // DIFile. A lexical block carries the file change while keeping
            // the subprogram, which is the shape LLVM verifies for.
            scope =
                self.debug_node(
                    "!DILexicalBlockFile(scope: !{self.debug_scope}, file: !{self.debug_file(use_file)}, discriminator: 0)")
        }
        return ", !dbg !{self.debug_node("!DILocation(line: {use_line}, column: {use_col}, scope: !{scope})")}"
    }

    // The location an instruction's own lines carry.
    fn debug_instruction_location(
            instruction: MirInstruction) -> string {
        return self.debug_location(
            instruction.file, instruction.line, instruction.col)
    }

    // The function's declaration line, for the prologue and epilogue the
    // emitter writes around the body. Those lines belong to no MIR
    // instruction, and `main`'s prologue alone calls `beans_os_init` and
    // every initializer — all of them calls, all of them covered by rule 2.
    fn debug_function_location() -> string {
        return self.debug_location(
            self.debug_scope_file, self.debug_scope_line, 1)
    }

    // What a `define` line carries in a debug build: the frame pointer this
    // mode has always claimed to keep, and the subprogram.
    //
    // `-fno-omit-frame-pointer` reaches Clang, and Clang applies it to the C
    // it compiles. A function that arrives as IR carries its own attributes
    // or none, so before this the Beans half of a `--debug` binary omitted
    // the frame pointer while the runtime kept it — visible as
    // DW_AT_APPLE_omit_frame_ptr on Beans frames alone, and as a stack a
    // frame-pointer walker loses at the first Beans call.
    fn debug_function_attributes(subprogram: int) -> string {
        if !self.debug_info { return "" }
        if subprogram < 0 { return " \"frame-pointer\"=\"all\"" }
        return " \"frame-pointer\"=\"all\" !dbg !{subprogram}"
    }

    // Every named metadata line the module has, written directly under
    // `target triple`. One function owns them because they share one list:
    // `!llvm.module.flags` carries the target's flags and the debug build's
    // together, and building it in two places would mean building it twice.
    //
    // Without `Debug Info Version` LLVM drops every debug node in silence, so
    // it is not optional decoration: it is what makes the rest of the file
    // mean anything.
    fn module_named_metadata() -> string {
        var flags: List<string> = []
        if self.program.target.os == "linux" {
            // Clang supplies these when compiling C for a distro-default PIE,
            // but an existing .ll module must state them itself. ppc32
            // otherwise emits a secure-PLT call with the wrong GOT base and
            // jumps to null on the first direct extern call.
            flags.push(
                "!{self.debug_node("!\{i32 7, !\"PIC Level\", i32 2\}")}")
            flags.push(
                "!{self.debug_node("!\{i32 7, !\"PIE Level\", i32 2\}")}")
        }
        var output: string = ""
        if self.debug_info {
            flags.push(
                "!{self.debug_node("!\{i32 2, !\"Debug Info Version\", i32 3\}")}")
            if self.debug_uses_codeview() {
                flags.push(
                    "!{self.debug_node("!\{i32 2, !\"CodeView\", i32 1\}")}")
            } else {
                // 4 rather than 5: every debugger in the support matrix reads
                // it, including the older GDB on the long-tail Linux targets,
                // and nothing here needs a version-5 feature.
                flags.push(
                    "!{self.debug_node("!\{i32 7, !\"Dwarf Version\", i32 4\}")}")
            }
            output = "!llvm.dbg.cu = !\{!{self.debug_unit}\}\n"
        }
        if flags.len() == 0 { return output }
        return "{output}!llvm.module.flags = !\{{flags.join(", ")}\}\n"
    }

    // The DIType for one Beans type, or -1 for a type the debugger is not
    // told about.
    //
    // Scalars are described exactly, so `frame variable` prints the value a
    // person wrote. Everything that lowers to a pointer is described as a
    // pointer carrying the Beans type's own name, so a list, a map or an
    // object reads as `List<int>` at an address rather than as an untyped
    // word. What that does not yet do is walk into an object and print its
    // fields; that needs the class layouts and a cycle guard, and it is a
    // separate piece of work from the line table.
    fn debug_type(type: HirType) -> int {
        if !self.debug_info { return -1 }
        let key: string = hir_type_key(type)
        match self.debug_type_ids.get(key) {
            some(found) => { return found }
            none => {}
        }
        let id: int = self.build_debug_type(type)
        self.debug_type_ids[key] = id
        return id
    }

    fn build_debug_type(type: HirType) -> int {
        let name: string = canonical_hir_name(type.name)
        let llvm: string = self.type_text(type)
        if llvm == "" || llvm == "void" { return -1 }
        if name == "bool" {
            // `i1` in registers, one byte in the slot the debugger reads
            return self.debug_node(
                "!DIBasicType(name: \"bool\", size: 8, encoding: DW_ATE_boolean)")
        }
        let bits: int = llvm_integer_bits(type)
        if bits > 0 {
            var encoding: string = "DW_ATE_signed"
            if llvm_type_is_unsigned(type) {
                encoding = "DW_ATE_unsigned"
            }
            return self.debug_node(
                "!DIBasicType(name: \"{name}\", size: {bits}, encoding: {encoding})")
        }
        if name == "f32" {
            return self.debug_node(
                "!DIBasicType(name: \"f32\", size: 32, encoding: DW_ATE_float)")
        }
        if name == "float" {
            return self.debug_node(
                "!DIBasicType(name: \"float\", size: 64, encoding: DW_ATE_float)")
        }
        if name == "string" {
            // A Beans string is the bytes themselves — the length lives in
            // the allocation header behind the pointer — and beans_alloc
            // hands back zeroed memory, so the byte after the last one is
            // always NUL. Describing it as `char *` is therefore true, and
            // it is what makes a debugger print the text instead of an
            // address.
            // The pointee must be spelled `char` exactly. A debugger prints a
            // pointer to a one-byte type as text only when it recognises the
            // C spelling; `u8` reads as an address instead.
            let byte: int = self.debug_node(
                "!DIBasicType(name: \"char\", size: 8, encoding: DW_ATE_signed_char)")
            return self.debug_named(
                "string", self.debug_pointer(byte))
        }
        if name == "Option" && type.args.len() == 1 &&
           self.type_is_reference(type.args[0]) {
            // `Option<C>` for a reference C is C's own pointer, with null
            // standing for none — there is no tag beside it. Describing it
            // as C is therefore true, and it is what lets a debugger walk a
            // linked structure instead of stopping at the first link.
            let inner: int = self.debug_type(type.args[0])
            if inner >= 0 {
                return self.debug_named(
                    render_hir_type(type), inner)
            }
        }
        if llvm == "ptr" {
            // A class value is the address of its own layout, and the
            // emitter already knows that layout exactly — it is the one it
            // allocates and indexes against. Describing it is what lets a
            // debugger print an object's fields instead of its address.
            //
            // An interface, an enum or a runtime handle reaches here too and
            // gets no layout: the concrete class behind an interface is not
            // known until run time, and a handle's fields belong to the C
            // runtime rather than to any Beans declaration.
            match self.class_layout(type) {
                some(layout) => {
                    let body: int =
                        self.debug_class_type(type, layout)
                    if body >= 0 {
                        return self.debug_named(
                            render_hir_type(type),
                            self.debug_pointer(body))
                    }
                }
                none => {}
            }
            return self.debug_named(
                render_hir_type(type),
                self.debug_pointer(-1))
        }
        // A struct or union is an inline value, so the composite is the
        // variable's type rather than something behind a pointer.
        match self.record_layout(type) {
            some(layout) => {
                return self.debug_record_type(type, layout)
            }
            none => {}
        }
        return -1
    }

    // The structure type for one class, made once per instantiation.
    //
    // The slot is reserved before the members are built. A class with a
    // field of its own type — a linked list, a tree, a parent pointer —
    // would otherwise ask for this node while it is still being made and
    // never stop asking; with the id already reserved, the field's own
    // lookup finds it and the recursion ends there.
    fn debug_class_type(type: HirType,
                        layout: LlvmClassLayout) -> int {
        let key: string = "class {render_hir_type(type)}"
        match self.debug_type_ids.get(key) {
            some(found) => { return found }
            none => {}
        }
        let id: int = self.debug_distinct_node("!\{\}")
        self.debug_type_ids[key] = id
        let file: int =
            self.debug_file(layout.declaration.file)
        var members: List<string> = []
        for field: HirField in layout.ordered_fields {
            if !layout.field_offsets.contains_key(field.name) {
                continue
            }
            if !layout.field_types.contains_key(field.name) {
                continue
            }
            let member: int =
                self.debug_member(
                    field,
                    layout.field_types[field.name],
                    layout.field_offsets[field.name],
                    id, file)
            if member >= 0 { members.push("!{member}") }
        }
        // Offset 0 holds the class descriptor the runtime dispatches and
        // collects through. It is deliberately not a member: a person
        // debugging their own object has no use for it, and DWARF is content
        // with a structure whose members do not cover every byte.
        self.debug_meta[id] =
            "distinct !DICompositeType(tag: DW_TAG_structure_type, name: \"{llvm_metadata_text(display_symbol(layout.declaration.qualified))}\", file: !{file}, line: {layout.declaration.line}, size: {layout.size * 8}, align: {layout.alignment * 8}, elements: !{self.debug_node("!\{{members.join(", ")}\}")})"
        return id
    }

    // The same for a struct or a union, which differ from a class in having
    // no descriptor word and, for a union, in every member sitting at zero.
    fn debug_record_type(type: HirType,
                         layout: LlvmRecordLayout) -> int {
        let key: string = "record {render_hir_type(type)}"
        match self.debug_type_ids.get(key) {
            some(found) => { return found }
            none => {}
        }
        let id: int = self.debug_distinct_node("!\{\}")
        self.debug_type_ids[key] = id
        let file: int =
            self.debug_file(layout.declaration.file)
        var members: List<string> = []
        for field: HirField in layout.declaration.fields {
            if !layout.field_offsets.contains_key(field.name) {
                continue
            }
            if !layout.field_types.contains_key(field.name) {
                continue
            }
            let member: int =
                self.debug_member(
                    field,
                    layout.field_types[field.name],
                    layout.field_offsets[field.name],
                    id, file)
            if member >= 0 { members.push("!{member}") }
        }
        var tag: string = "DW_TAG_structure_type"
        if layout.is_union { tag = "DW_TAG_union_type" }
        self.debug_meta[id] =
            "distinct !DICompositeType(tag: {tag}, name: \"{llvm_metadata_text(display_symbol(layout.declaration.qualified))}\", file: !{file}, line: {layout.declaration.line}, size: {layout.size * 8}, align: {layout.alignment * 8}, elements: !{self.debug_node("!\{{members.join(", ")}\}")})"
        return id
    }

    // One field of a composite. -1 for a field whose type the debugger is
    // not told about, and the composite then simply does not mention it —
    // a partly described object still prints the fields it knows.
    fn debug_member(field: HirField, type: HirType,
                    offset: int, owner: int,
                    file: int) -> int {
        let described: int = self.debug_type(type)
        if described < 0 { return -1 }
        let size: int = self.type_size(type)
        if size <= 0 { return -1 }
        return self.debug_node(
            "!DIDerivedType(tag: DW_TAG_member, name: \"{llvm_metadata_text(field.name)}\", scope: !{owner}, file: !{file}, line: {field.line}, baseType: !{described}, size: {size * 8}, offset: {offset * 8})")
    }

    fn debug_pointer(base: int) -> int {
        var to: string = "null"
        if base >= 0 { to = "!{base}" }
        return self.debug_node(
            "!DIDerivedType(tag: DW_TAG_pointer_type, baseType: {to}, size: {self.program.target.pointer_bits})")
    }

    // The Beans spelling of a type, over whatever it lowers to.
    //
    // A pointer's own `name:` field is not what a debugger prints — it prints
    // the pointee — so the Beans name is carried by a typedef instead. That
    // is what makes a variables pane read `List<string>` rather than `void *`,
    // and it still resolves through to `char *` for a string's text.
    fn debug_named(name: string, base: int) -> int {
        if base < 0 { return -1 }
        return self.debug_node(
            "!DIDerivedType(tag: DW_TAG_typedef, name: \"{llvm_metadata_text(name)}\", baseType: !{base})")
    }

    // The `llvm.dbg.declare` that ties one stack slot to one source name.
    //
    // Every local is a slot at -O0, so there is nothing to reconstruct: the
    // alloca is the variable's address and the debugger reads it directly. A
    // captured local is one indirection further out — its slot holds the
    // pointer to a heap cell — and DW_OP_deref is exactly that step.
    //
    // Compiler temporaries are left out. They have no binding and their names
    // start with '$'; naming them would fill a Variables pane with the
    // lowering's own bookkeeping.
    fn debug_declare(local: MirLocal, argument: int,
                     indirect: bool) -> string {
        if !self.debug_info { return "" }
        if self.debug_scope < 0 { return "" }
        if local.binding_id < 0 { return "" }
        if local.name == "" || local.name.starts_with("$") {
            return ""
        }
        let type: int = self.debug_type(local.type)
        if type < 0 { return "" }
        var position: string = ""
        if argument > 0 { position = "arg: {argument}, " }
        // distinct: two locals can share a name in one function, and one
        // shared node would leave the debugger showing one slot twice.
        let variable: int = self.debug_distinct_node(
            "distinct !DILocalVariable(name: \"{llvm_metadata_text(local.name)}\", {position}scope: !{self.debug_scope}, file: !{self.debug_file(self.debug_scope_file)}, line: {self.debug_scope_line}, type: !{type})")
        var expression: string = "!DIExpression()"
        if indirect { expression = "!DIExpression(DW_OP_deref)" }
        return "  call void @llvm.dbg.declare(metadata ptr %l{local.id}, metadata !{variable}, metadata {expression})\n"
    }

    // The intrinsic the declares above call. Declared only in a build that
    // has some.
    fn debug_module_declares() -> string {
        if !self.debug_info { return "" }
        return "declare void @llvm.dbg.declare(metadata, metadata, metadata)\n"
    }

    // MSVC records debug information as CodeView; every other Windows
    // environment Beans targets is a MinGW or LLVM one that reads DWARF.
    fn debug_uses_codeview() -> bool {
        return self.program.target.os == "windows" &&
               self.program.target.llvm_triple().ends_with("-msvc")
    }

    // Every node, defined once, at the end of the module. Order is allocation
    // order, so identical sources produce an identical block and a debug
    // build stays as reproducible as every other one.
    fn debug_module_metadata() -> string {
        if self.debug_meta.len() == 0 { return "" }
        var lines: List<string> = ["\n"]
        for index: int in 0..self.debug_meta.len() {
            lines.push("!{index} = {self.debug_meta[index]}\n")
        }
        return lines.join("")
    }
}

// Appends `suffix` to every LLVM instruction in an emitted chunk.
//
// The emitter builds its module as text, so the line table is attached as
// text too. This walks the chunk a line at a time and decorates the lines
// that are instructions: a blank line, a comment, a block label and anything
// at module level are left exactly as they were.
//
// The bracket depth is what makes it safe. `switch` is the one instruction
// this emitter spreads over several lines — an enum match writes its cases
// one per line — and its metadata belongs after the `]` that closes it, not
// after each case. Counting `[` and `]` puts it there and leaves a balanced
// `[4 x i64]` alone.
fn llvm_attach_dbg(text: string, suffix: string) -> string {
    if suffix == "" || text == "" { return text }
    var out: List<string> = []
    var start: int = 0
    var depth: int = 0
    for start < text.len() {
        let end: int = llvm_line_end(text, start)
        let line: string = text.slice(start, end)
        let opened: int = depth
        depth = depth + llvm_bracket_delta(line)
        if depth < 0 { depth = 0 }
        if opened == 0 && depth == 0 &&
           llvm_line_takes_dbg(line) {
            out.push("{line}{suffix}")
        } else {
            out.push(line)
        }
        if end < text.len() { out.push("\n") }
        start = end + 1
    }
    return out.join("")
}

// `[` minus `]` over one line. Square brackets are the only pair this
// emitter ever leaves open across a line break.
fn llvm_bracket_delta(line: string) -> int {
    var delta: int = 0
    for index: int in 0..line.len() {
        let byte: int = line.byte_at(index)
        if byte == 91 { delta += 1 }
        if byte == 93 { delta -= 1 }
    }
    return delta
}

// Whether a line is an instruction, and so can carry a location.
//
// Everything rejected here either cannot take metadata — a label, a comment,
// a brace — or is module level and belongs to no function. The emitter never
// puts a global or a nested `define` inside an instruction's own text, so the
// module-level tests are a guard rather than a working part of the pass.
fn llvm_line_takes_dbg(line: string) -> bool {
    var start: int = 0
    for start < line.len() &&
        (line.byte_at(start) == 32 || line.byte_at(start) == 9) {
        start += 1
    }
    if start >= line.len() { return false }
    let head: int = line.byte_at(start)
    // ';' comment, '{' or '}' brace, '@' global, '!' metadata
    if head == 59 || head == 123 || head == 125 ||
       head == 64 || head == 33 {
        return false
    }
    var end: int = line.len()
    for end > start &&
        (line.byte_at(end - 1) == 32 || line.byte_at(end - 1) == 9) {
        end -= 1
    }
    if end <= start { return false }
    // a block label — the only line that ends in ':'
    if line.byte_at(end - 1) == 58 { return false }
    let body: string = line.slice(start, end)
    if body.starts_with("define ") ||
       body.starts_with("declare ") ||
       body.starts_with("target ") ||
       body.starts_with("source_filename") ||
       body.starts_with("attributes ") {
        return false
    }
    return true
}

// One metadata string, escaped the way LLVM reads it back.
//
// A path can hold a quote or a backslash — a Windows one holds backslashes by
// nature — and either would end the string early. `\XX` is LLVM's escape and
// the only one it accepts inside a metadata string.
fn llvm_metadata_text(value: string) -> string {
    var out: List<string> = []
    for index: int in 0..value.len() {
        let byte: int = value.byte_at(index)
        if byte == 34 || byte == 92 || byte < 32 || byte == 127 {
            out.push("\\{llvm_metadata_hex(byte)}")
        } else {
            out.push(value.slice(index, index + 1))
        }
    }
    return out.join("")
}

fn llvm_metadata_hex(byte: int) -> string {
    let digits: string = "0123456789ABCDEF"
    let high: int = (byte >> 4) & 15
    let low: int = byte & 15
    return "{digits.slice(high, high + 1)}{digits.slice(low, low + 1)}"
}
