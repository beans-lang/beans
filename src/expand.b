package main

import std.io
import std.os

// The async expander: the one shared lowering for async functions.
//
// After expression checking succeeds, every `async fn` body is rewritten
// into a synchronous task maker. To the user the function's type is still
// `fn(int) -> R` — asyncness is an effect — but after expansion the maker
// really returns the internal task record:
//
//     fn f(a: int) -> async$rt.Task<R> {
//         ...one slot list per local that lives across a suspension...
//         var state$: int = 0
//         var result$: List<R> = []
//         return new async$rt.Task<R>(
//             fn() -> int { for { if state$ == 0 { ... } ... } },
//             fn() -> R { return result$.remove(0) },
//             fn() { ...armed defers, newest first... })
//     }
//
// `async fn main` is the exception: it keeps its unit result and, instead
// of returning the task, drives it to completion in place — that loop is
// the hidden executor's root.
//
// The maker's locals are captured by the three closures, so the closure
// environment — the heap cells both backends already share between
// closures — is the task frame. There is no separate frame object, no new
// MIR operation, and no new runtime hook: the rewritten body is ordinary
// Beans, re-checked by the ordinary checker, executed by the ordinary
// interpreter, and lowered by the ordinary MIR and LLVM pipeline. Original
// expression nodes are transplanted, so runtime panics still point at the
// user's source.
//
// The rules:
//   - The body becomes flat states. Every state ends by moving to another
//     state (`state$ = K` and re-entering the dispatch loop), suspending
//     (`return 0`), or completing (`return 1`).
//   - `await E` stores E's task in a one-slot list, suspends until
//     poll_once() reports ready, then moves the task out and takes its
//     value.
//   - A local that lives across a suspension (or is referenced by a
//     defer, or is a move parameter) becomes a one-slot List: empty means
//     uninitialized, push initializes, an indexed read borrows, remove(0)
//     moves out, clear() is the scope-exit drop. Conditional
//     initialization, moves, and exact-once release all fall out of the
//     list's own rules.
//   - String pieces re-resolve names when the maker is re-checked, so a
//     statement whose interpolations read a slotted local is wrapped in a
//     one-element loop that re-binds the original name as a borrow.
//   - Every suspension first gives each live async let child of the
//     frame one poll, first declared first — that scan is what lets a
//     child progress while a sibling's await is parked, and it repeats
//     on every re-poll, so no child starves.
//   - `return` and `?` run the armed defers newest-first, store the
//     completion value, and transition to a shared cleanup state that
//     clears every slot last-created-first — the order plain locals
//     drop in, defined the same for both compilers. The cancel closure
//     runs the armed defers and the same clears when an unfinished task
//     is dropped, so children cancel in cascade as their slots clear.
//   - main's drive loop matches what the loader loaded: when the
//     readiness half of the async runtime is present (std.net loaded),
//     a pending root blocks in the reactor driver; without it the loop
//     calls the poller-free stall, which reports the async deadlock.
//     That choice is what keeps every poller symbol out of pure async
//     programs, so they link under the minimal and freestanding
//     runtime profiles.

fn ast_contains_await(node: AstNode) -> bool {
    if node.kind == "await" { return true }
    for child: AstNode in node.children {
        if ast_contains_await(child) { return true }
    }
    return false
}

// Names a defer expression mentions; any local by one of these names is
// slotted so the defer body can run at any exit.
fn ast_names_in(node: AstNode, inout names: Map<string, bool>) {
    if node.kind == "name" { names[node.value] = true }
    for child: AstNode in node.children {
        ast_names_in(child, inout names)
    }
}

// A place expression re-evaluates without side effects, so it does not
// need hoisting to survive a suspension between its evaluation order slot
// and its use.
fn ast_is_pure_place(node: AstNode) -> bool {
    if node.kind == "name" { return true }
    if node.kind == "literal" {
        return node.children.len() == 0
    }
    if node.kind == "field" {
        return ast_is_pure_place(node.children[0])
    }
    if node.kind == "index" {
        return ast_is_pure_place(node.children[0]) &&
               ast_is_pure_place(node.children[1])
    }
    return false
}

class AsyncSlot {
    name: string
    slot: string
    type: HirType
    // A masking entry: the name is re-bound as a real borrow (loop
    // binding), so substitution must leave it alone.
    masked: bool
    // An async let child: completion clears it before the result lands,
    // so the parent never finishes while a child still holds anything.
    is_child: bool

    fn init(name: string, slot: string, type: HirType) {
        self.name = name
        self.slot = slot
        self.type = type
        self.masked = false
        self.is_child = false
    }
}

class AsyncScope {
    bindings: Map<string, AsyncSlot>
    // Declaration order of the real slots in this scope. Map promises no
    // iteration order, and both the sibling scan (first declared first)
    // and the scope-exit clears (last declared first, like local drops)
    // are observable behavior the two compilers must agree on.
    order: List<string>

    fn init() {
        self.bindings = {}
        self.order = []
    }
}

class AsyncArmSlots {
    names: List<string>

    fn init() {
        self.names = []
    }
}

class AsyncDefer {
    flag: string
    body: AstNode

    fn init(flag: string, body: AstNode) {
        self.flag = flag
        self.body = body
    }
}

class AsyncLoopContext {
    continue_state: int
    exit_state: int
    // Slots declared inside the loop, cleared on break/continue so one
    // iteration's value cannot leak into the next or past the loop.
    slots_inside: List<string>

    fn init(continue_state: int, exit_state: int) {
        self.continue_state = continue_state
        self.exit_state = exit_state
        self.slots_inside = []
    }
}

class AsyncExpander {
    signature: SignatureChecker
    program: HirProgram
    errors: List<Diagnostic>
    function: HirFunction
    states: List<AstNode>
    current_state: int
    slot_decls: List<AstNode>
    scopes: List<AsyncScope>
    defer_names: Map<string, bool>
    defers: List<AsyncDefer>
    loop_stack: List<AsyncLoopContext>
    counter: int
    body_is_unit: bool
    // The shared terminal state every completion transitions to: filled
    // at the end of expansion, when every slot is known, with the
    // reverse-creation clears and the final return.
    cleanup_state: int
    // Names of the genuine list slots, in creation order. slot_decls
    // also holds the plain bool defer flags, which have nothing to
    // clear, and result$ registers here but is skipped: the take reads
    // it after the final poll returns.
    slot_names: List<string>
    // Whether the loader brought in the readiness half of the async
    // runtime (reactor.b — present exactly when std.net is loaded).
    // Decides which driver main's drive loop calls: the blocking
    // reactor driver, or the poller-free stall that reports deadlock.
    has_reactor: bool

    fn init(signature: SignatureChecker) {
        self.signature = signature
        self.program = signature.hir
        self.errors = []
        self.function = new HirFunction(
            "", "", "", false, false, "", 0, 0)
        self.states = []
        self.current_state = 0
        self.slot_decls = []
        self.scopes = []
        self.defer_names = {}
        self.defers = []
        self.loop_stack = []
        self.counter = 0
        self.body_is_unit = false
        self.cleanup_state = 0
        self.slot_names = []
        self.has_reactor = false
        for function: HirFunction in self.program.functions {
            if function.qualified == async_rt_symbol("driver_wait") {
                self.has_reactor = true
            }
        }
    }

    fn fail(node: AstNode, message: string) {
        self.errors.push(Diagnostic {
            severity: Severity.error,
            file: self.function.file,
            line: node.line,
            col: node.col,
            message: message,
        })
    }

    // ---- AST building helpers ----------------------------------------

    fn node(kind: string, value: string, anchor: AstNode) -> AstNode {
        return new AstNode(kind, value, anchor.line, anchor.col)
    }

    fn name_of(name: string, anchor: AstNode) -> AstNode {
        return self.node("name", name, anchor)
    }

    fn int_literal(value: int, anchor: AstNode) -> AstNode {
        let result: AstNode = self.node("literal", "{value}", anchor)
        result.note = "int"
        return result
    }

    fn bool_literal(value: bool, anchor: AstNode) -> AstNode {
        let text: string = if value { "true" } else { "false" }
        let result: AstNode = self.node("literal", text, anchor)
        result.note = text
        return result
    }

    fn type_ast(type: HirType, anchor: AstNode) -> AstNode {
        if type.name == "array" {
            let result: AstNode =
                self.node("array_type", "{type.array_length}", anchor)
            result.add(self.type_ast(type.args[0], anchor))
            return result
        }
        if type.name == "fn" {
            let result: AstNode = self.node("fn_type", "", anchor)
            if type.fn_sendable { result.value = "send" }
            for argument: HirType in type.args {
                result.add(self.type_ast(argument, anchor))
            }
            if type.fn_parameter_count < type.args.len() {
                result.note = "has_result"
            }
            return result
        }
        let result: AstNode = self.node("type", type.name, anchor)
        result.resolved = type.name
        for argument: HirType in type.args {
            result.add(self.type_ast(argument, anchor))
        }
        return result
    }

    fn slot_declaration(slot: string, element: HirType,
                        anchor: AstNode) -> AstNode {
        // every genuine one-element list slot registers its name here;
        // the cleanup state and the cancel closure clear exactly these
        self.slot_names.push(slot)
        let declaration: AstNode = self.node("var", slot, anchor)
        declaration.add(self.type_ast(hir_list(element), anchor))
        declaration.add(self.node("list", "", anchor))
        return declaration
    }

    fn statement_of(expression: AstNode) -> AstNode {
        let statement: AstNode =
            self.node("expression", "", expression)
        statement.add(expression)
        return statement
    }

    fn call_method(receiver: AstNode, method: string,
                   arguments: List<AstNode>, anchor: AstNode) -> AstNode {
        let field: AstNode = self.node("field", method, anchor)
        field.add(receiver)
        let call: AstNode = self.node("call", "", anchor)
        call.add(field)
        for argument: AstNode in arguments {
            call.add(argument)
        }
        return call
    }

    fn slot_read(slot: string, anchor: AstNode) -> AstNode {
        let index: AstNode = self.node("index", "", anchor)
        index.add(self.name_of(slot, anchor))
        index.add(self.int_literal(0, anchor))
        return index
    }

    fn slot_take(slot: string, anchor: AstNode) -> AstNode {
        return self.call_method(
            self.name_of(slot, anchor), "remove",
            [self.int_literal(0, anchor)], anchor)
    }

    fn slot_push(slot: string, value: AstNode, anchor: AstNode) -> AstNode {
        return self.statement_of(self.call_method(
            self.name_of(slot, anchor), "push", [value], anchor))
    }

    // Statement-level slot initialization. The value lands in a typed
    // local first so literals, err(...), ok(...), none and friends see the
    // declared type, exactly as they would in the original source spot.
    fn emit_slot_push(slot: string, element: HirType, value: AstNode,
                      anchor: AstNode) {
        if value.kind == "name" || value.kind == "index" {
            self.emit(self.slot_push(slot, value, anchor))
            return
        }
        let carry: string = self.fresh_name("carry_")
        let declaration: AstNode = self.node("let", carry, anchor)
        declaration.add(self.type_ast(element, anchor))
        declaration.add(value)
        self.emit(declaration)
        let taken: AstNode = self.node("unary", "move", anchor)
        taken.add(self.name_of(carry, anchor))
        self.emit(self.slot_push(slot, taken, anchor))
    }

    fn slot_clear(slot: string, anchor: AstNode) -> AstNode {
        return self.statement_of(self.call_method(
            self.name_of(slot, anchor), "clear", [], anchor))
    }

    fn assign_statement(target: AstNode, value: AstNode,
                        anchor: AstNode) -> AstNode {
        let assignment: AstNode = self.node("assign", "=", anchor)
        assignment.add(target)
        assignment.add(value)
        return assignment
    }

    fn set_state_statement(target: int, anchor: AstNode) -> AstNode {
        return self.assign_statement(
            self.name_of("state$", anchor),
            self.int_literal(target, anchor), anchor)
    }

    fn return_int(value: int, anchor: AstNode) -> AstNode {
        let result: AstNode = self.node("return", "", anchor)
        result.add(self.int_literal(value, anchor))
        return result
    }

    // ---- state management --------------------------------------------

    fn emit(statement: AstNode) {
        self.states[self.current_state].add(statement)
    }

    fn new_state(anchor: AstNode) -> int {
        let id: int = self.states.len()
        self.states.push(self.node("block", "", anchor))
        return id
    }

    fn emit_transition(target: int, anchor: AstNode) {
        self.emit(self.set_state_statement(target, anchor))
        self.emit(self.node("continue", "", anchor))
    }

    fn enter_state(id: int) {
        self.current_state = id
    }

    // A two-way branch on a rewritten condition where each side only picks
    // the next state.
    fn emit_state_branch(condition: AstNode, on_true: int, on_false: int,
                         anchor: AstNode) {
        let guard: AstNode = self.node("if", "", anchor)
        guard.add(condition)
        let yes: AstNode = self.node("block", "", anchor)
        yes.add(self.set_state_statement(on_true, anchor))
        guard.add(yes)
        let no: AstNode = self.node("block", "", anchor)
        no.add(self.set_state_statement(on_false, anchor))
        guard.add(no)
        self.emit(guard)
        self.emit(self.node("continue", "", anchor))
    }

    // ---- scopes and substitution -------------------------------------

    fn push_scope() {
        self.scopes.push(new AsyncScope())
    }

    fn pop_scope(emit_clears: bool, anchor: AstNode) {
        let scope: AsyncScope =
            self.scopes[self.scopes.len() - 1]
        if emit_clears {
            // Last declared clears first, matching how plain locals drop
            // at the end of a scope. For an async let child the clear is
            // the cancellation, so children cancel newest-first too.
            var index: int = scope.order.len() - 1
            for index >= 0 {
                let slot: AsyncSlot =
                    scope.bindings[scope.order[index]]
                if !slot.masked {
                    self.emit(self.slot_clear(slot.slot, anchor))
                }
                index -= 1
            }
        }
        self.scopes.pop()
    }

    fn find_slot(name: string) -> Option<AsyncSlot> {
        var index: int = self.scopes.len() - 1
        for index >= 0 {
            match self.scopes[index].bindings.get(name) {
                some(slot) => {
                    if slot.masked { return none }
                    return some(slot)
                }
                none => {}
            }
            index -= 1
        }
        return none
    }

    fn fresh_name(base: string) -> string {
        let name: string = "{base}{self.counter}$"
        self.counter += 1
        return name
    }

    fn checked_type(node: AstNode) -> HirType {
        match node.checked {
            some(lowered) => { return lowered.type }
            none => {}
        }
        self.fail(
            node,
            "internal: async expander found an unchecked {node.kind} node")
        return poison_hir_type()
    }

    fn declare_slot(name: string, type: HirType,
                    anchor: AstNode) -> AsyncSlot {
        let slot: AsyncSlot = new AsyncSlot(
            name, self.fresh_name("{name}_"), type)
        self.slot_decls.push(
            self.slot_declaration(slot.slot, type, anchor))
        self.scopes[self.scopes.len() - 1].bindings[name] = slot
        self.scopes[self.scopes.len() - 1].order.push(name)
        if self.loop_stack.len() != 0 {
            let context: AsyncLoopContext =
                self.loop_stack[self.loop_stack.len() - 1]
            context.slots_inside.push(slot.slot)
        }
        return slot
    }

    // Rewrites an await-free expression: reads of slotted locals become
    // indexed borrows, `move x` of a slotted local becomes remove(0).
    // Everything else is transplanted untouched with its source position.
    fn substitute(node: AstNode) -> AstNode {
        if node.kind == "name" {
            match self.find_slot(node.value) {
                some(slot) => {
                    return self.slot_read(slot.slot, node)
                }
                none => { return node }
            }
        }
        if node.kind == "unary" && node.value == "move" &&
           node.children.len() == 1 &&
           node.children[0].kind == "name" {
            match self.find_slot(node.children[0].value) {
                some(slot) => {
                    return self.slot_take(slot.slot, node)
                }
                none => { return node }
            }
        }
        // A compound assign to a slotted name would substitute into
        // `slot$[0] += v`, and list index assignment only supports `=`,
        // so it becomes `slot$[0] = slot$[0] op v` instead.
        if node.kind == "assign" && node.value != "=" &&
           node.children.len() == 2 &&
           node.children[0].kind == "name" {
            match self.find_slot(node.children[0].value) {
                some(slot) => {
                    let combined: AstNode = self.node(
                        "binary",
                        node.value.slice(0, node.value.len() - 1),
                        node)
                    combined.add(self.slot_read(slot.slot, node))
                    combined.add(self.substitute(node.children[1]))
                    let plain: AstNode = self.node("assign", "=", node)
                    plain.add(self.slot_read(slot.slot, node))
                    plain.add(combined)
                    return plain
                }
                none => {}
            }
        }
        var index: int = 0
        for index < node.children.len() {
            node.children[index] =
                self.substitute(node.children[index])
            index += 1
        }
        return node
    }

    // Slotted names read by this statement's string interpolations. The
    // re-check re-resolves piece text by name, so those names must exist
    // as real bindings around the statement.
    fn interpolated_slot_names(node: AstNode,
                               inout found: Map<string, bool>) {
        if node.kind == "literal" && node.children.len() == 0 {
            match node.checked {
                some(lowered) => {
                    self.piece_slot_names(lowered, inout found)
                }
                none => {}
            }
        }
        for child: AstNode in node.children {
            self.interpolated_slot_names(child, inout found)
        }
    }

    fn thread_capture_slot_names(node: AstNode,
                                 inout found: Map<string, bool>) {
        var is_spawn: bool = false
        match node.checked {
            some(checked) => {
                is_spawn = checked.resolved == "std.thread.spawn"
            }
            none => {}
        }
        if is_spawn {
            var inner: Map<string, bool> = {}
            ast_names_in(node, inout inner)
            for name: string in inner.keys() {
                if self.find_slot(name).is_some() {
                    found[name] = true
                }
            }
            return
        }
        for child: AstNode in node.children {
            self.thread_capture_slot_names(child, inout found)
        }
    }

    fn piece_slot_names(node: HirNode,
                        inout found: Map<string, bool>) {
        if node.kind == "local" &&
           self.find_slot(node.value).is_some() {
            found[node.value] = true
        }
        for child: HirNode in node.children {
            self.piece_slot_names(child, inout found)
        }
    }

    // Emits a statement, wrapping it in one-element borrow loops for every
    // slotted name its interpolations read, so re-checked piece text
    // resolves. Assignments to those names inside the same statement
    // cannot work under the borrow and are refused.
    fn emit_with_piece_bindings(statement: AstNode) {
        self.emit(self.wrap_for_pieces(statement))
    }

    fn wrap_for_pieces(statement: AstNode) -> AstNode {
        var names: Map<string, bool> = {}
        self.interpolated_slot_names(statement, inout names)
        // A thread closure must capture Send values, never the one-slot
        // List a suspended local lives in — re-bind those names as plain
        // borrows the same way interpolation pieces are.
        self.thread_capture_slot_names(statement, inout names)
        if names.len() == 0 {
            return self.substitute(statement)
        }
        var wrap_slots: List<AsyncSlot> = []
        for name: string in names.keys() {
            match self.find_slot(name) {
                some(slot) => { wrap_slots.push(slot) }
                none => {}
            }
        }
        self.push_scope()
        for slot: AsyncSlot in wrap_slots {
            let mask: AsyncSlot = new AsyncSlot(
                slot.name, "", slot.type)
            mask.masked = true
            self.scopes[self.scopes.len() - 1].bindings[slot.name] = mask
        }
        if self.statement_assigns_any(statement, names) {
            self.fail(
                statement,
                "internal: a statement cannot assign a suspended local it also interpolates — split it in the source")
        }
        var wrapped: AstNode = self.substitute(statement)
        var index: int = wrap_slots.len() - 1
        for index >= 0 {
            let slot: AsyncSlot = wrap_slots[index]
            let loop_node: AstNode =
                self.node("for", slot.name, statement)
            let binding: AstNode =
                self.node("binding", slot.name, statement)
            binding.add(self.type_ast(slot.type, statement))
            loop_node.add(binding)
            loop_node.add(self.name_of(slot.slot, statement))
            let body: AstNode = self.node("block", "", statement)
            body.add(wrapped)
            loop_node.add(body)
            wrapped = loop_node
            index -= 1
        }
        self.pop_scope(false, statement)
        return wrapped
    }

    fn statement_assigns_any(node: AstNode,
                             names: Map<string, bool>) -> bool {
        if node.kind == "assign" &&
           node.children[0].kind == "name" &&
           names.contains_key(node.children[0].value) {
            return true
        }
        for child: AstNode in node.children {
            if self.statement_assigns_any(child, names) {
                return true
            }
        }
        return false
    }

    // ---- await decomposition -----------------------------------------

    fn decompose(node: AstNode) -> AstNode {
        if !ast_contains_await(node) {
            return self.substitute(node)
        }
        if node.kind == "await" {
            return self.decompose_await(node)
        }
        if node.kind == "binary" &&
           (node.value == "&&" || node.value == "||") {
            return self.decompose_short_circuit(node)
        }
        if node.kind == "try" {
            let operand: AstNode = self.decompose(node.children[0])
            return self.rewrite_try(node, operand)
        }
        if node.kind == "if_expression" {
            let value_type: HirType = self.checked_type(node)
            let out: string = self.fresh_name("pick_")
            self.slot_decls.push(
                self.slot_declaration(out, value_type, node))
            self.decompose_if_value(node, out, value_type)
            return self.slot_take(out, node)
        }
        if node.kind == "match" {
            let value_type: HirType = self.checked_type(node)
            let out: string = self.fresh_name("pick_")
            self.slot_decls.push(
                self.slot_declaration(out, value_type, node))
            self.decompose_match(node, some(out), value_type)
            return self.slot_take(out, node)
        }
        // Children evaluate left to right; whatever runs before a later
        // suspension must be kept in a slot rather than re-evaluated.
        var last_await: int = -1
        var index: int = 0
        for index < node.children.len() {
            if ast_contains_await(node.children[index]) {
                last_await = index
            }
            index += 1
        }
        index = 0
        for index < node.children.len() {
            let child: AstNode = node.children[index]
            if index < last_await &&
               !self.hoist_exempt(node, index) &&
               !ast_is_pure_place(child) {
                if ast_contains_await(child) {
                    node.children[index] = self.decompose(child)
                } else {
                    let child_type: HirType = self.checked_type(child)
                    let keep: string = self.fresh_name("kept_")
                    self.slot_decls.push(self.slot_declaration(
                        keep, child_type, child))
                    self.emit_slot_push(
                        keep, child_type, self.substitute(child), child)
                    node.children[index] = self.slot_take(keep, child)
                }
            } else if ast_contains_await(child) {
                node.children[index] = self.decompose(child)
            } else {
                node.children[index] = self.substitute(child)
            }
            index += 1
        }
        return node
    }

    // Positions that are not first-class values: callee names, constructor
    // types, cast types. A method callee's receiver does need hoisting,
    // which the field-node recursion above provides because the field is
    // decomposed or substituted as a child in its own right.
    fn hoist_exempt(node: AstNode, index: int) -> bool {
        if node.kind == "call" && index == 0 {
            let callee: AstNode = node.children[index]
            if callee.kind == "name" { return true }
            if callee.kind == "field" {
                return ast_is_pure_place(callee.children[0])
            }
            return false
        }
        if node.kind == "new" && index == 0 { return true }
        if node.kind == "cast" && index == 1 { return true }
        return false
    }

    // net.readable / net.writable are compiler-known: their
    // declared bodies never run. The call swaps for a parked readiness
    // await on the hidden reactor, argument already decomposed in place.
    fn readiness_swap(operand: AstNode) -> AstNode {
        var target: string = ""
        match operand.checked {
            some(checked) => { target = checked.resolved }
            none => {}
        }
        // std.net is a source package, so its functions carry canonical
        // symbols; matching the short spelling here would silently stop
        // parking awaits.
        if target != package_symbol("std.net", "readable") &&
           target != package_symbol("std.net", "writable") {
            return operand
        }
        let park: AstNode = self.node("call", "", operand)
        let callee: AstNode = self.node(
            "name", "reactor_park", operand)
        callee.resolved = async_rt_symbol("reactor_park")
        park.add(callee)
        park.add(operand.children[1])
        park.add(self.bool_literal(
            target == package_symbol("std.net", "writable"),
            operand))
        return park
    }

    fn decompose_await(node: AstNode) -> AstNode {
        // Awaiting an async let binding: the child's task is already in
        // the binding's slot, so the poll/take tail runs on it directly.
        // The take empties the slot, which is what makes the scope-exit
        // clear a no-op for an awaited child.
        if node.children[0].kind == "name" {
            let child_value: HirType = self.checked_type(node)
            match self.find_slot(node.children[0].value) {
                some(child) => {
                    return self.drain_task_slot(
                        child.slot, child_value, node)
                }
                none => {}
            }
        }
        let operand: AstNode = self.readiness_swap(
            self.decompose(node.children[0]))
        // The operand is a checked async call, so its type is the result
        // R (asyncness is an effect); the maker it becomes after the
        // signature flip really hands back the internal task.
        let value_type: HirType = self.checked_type(node.children[0])
        let task_type: HirType =
            hir_named(async_rt_symbol("Task"), [value_type])
        let wait: string = self.fresh_name("await_")
        self.slot_decls.push(
            self.slot_declaration(wait, task_type, node))
        self.emit_slot_push(wait, task_type, operand, node)
        return self.drain_task_slot(wait, value_type, node)
    }

    // The sibling scan, emitted into every suspension: while this frame
    // is about to report pending, every live async let child of the frame
    // gets one poll, first declared first. This is what lets a child
    // progress while another child's await is parked. The scan re-runs on
    // every re-poll of the frame, so a full pass happens each cycle and
    // no child starves; a finished child answers from its `finished` flag
    // without re-entering its body, and a child's own scan reaches the
    // grandchildren, so the poll depth is bounded by the task tree.
    fn append_child_scan(pending: AstNode, wait: string,
                         anchor: AstNode) {
        var scope_index: int = 0
        for scope_index < self.scopes.len() {
            let scope: AsyncScope = self.scopes[scope_index]
            for name: string in scope.order {
                let slot: AsyncSlot = scope.bindings[name]
                if !slot.is_child || slot.masked ||
                   slot.slot == wait {
                    continue
                }
                // if child$.len() != 0 { let step$: int =
                //     child$[0].poll_once() }
                let occupied: AstNode =
                    self.node("binary", "!=", anchor)
                occupied.add(self.call_method(
                    self.name_of(slot.slot, anchor), "len", [],
                    anchor))
                occupied.add(self.int_literal(0, anchor))
                let poll_child: AstNode = self.node("if", "", anchor)
                poll_child.add(occupied)
                let body: AstNode = self.node("block", "", anchor)
                let step: string = self.fresh_name("step_")
                let step_decl: AstNode = self.node("let", step, anchor)
                let step_type: AstNode =
                    self.node("type", "int", anchor)
                step_type.resolved = "int"
                step_decl.add(step_type)
                step_decl.add(self.call_method(
                    self.slot_read(slot.slot, anchor), "poll_once",
                    [], anchor))
                body.add(step_decl)
                poll_child.add(body)
                pending.add(poll_child)
            }
            scope_index += 1
        }
    }

    // The shared await tail: suspend until the task in `slot` reports
    // ready, then move it out and take its value.
    fn drain_task_slot(wait: string, value_type: HirType,
                       node: AstNode) -> AstNode {
        let task_type: HirType =
            hir_named(async_rt_symbol("Task"), [value_type])
        let poll_state: int = self.new_state(node)
        self.emit_transition(poll_state, node)
        self.enter_state(poll_state)
        // if wait$[0].poll_once() == 0 { <poll siblings>; return 0 }
        let poll: AstNode = self.call_method(
            self.slot_read(wait, node), "poll_once", [], node)
        let compare: AstNode = self.node("binary", "==", node)
        compare.add(poll)
        compare.add(self.int_literal(0, node))
        let suspend: AstNode = self.node("if", "", node)
        suspend.add(compare)
        let pending: AstNode = self.node("block", "", node)
        self.append_child_scan(pending, wait, node)
        pending.add(self.return_int(0, node))
        suspend.add(pending)
        self.emit(suspend)
        // let done$: Task<U> = wait$.remove(0)
        let done: string = self.fresh_name("done_")
        let done_decl: AstNode = self.node("let", done, node)
        done_decl.add(self.type_ast(task_type, node))
        done_decl.add(self.slot_take(wait, node))
        self.emit(done_decl)
        // let taken$: fn() -> U = done$.take_fn
        let taker: string = self.fresh_name("taken_")
        let taker_decl: AstNode = self.node("let", taker, node)
        taker_decl.add(self.type_ast(
            hir_function([], value_type), node))
        let take_read: AstNode = self.node("field", "take_fn", node)
        take_read.add(self.name_of(done, node))
        taker_decl.add(take_read)
        self.emit(taker_decl)
        let invoke: AstNode = self.node("call", "", node)
        invoke.add(self.name_of(taker, node))
        // A unit value has no slot to ride in — List<unit> is not a real
        // container for either backend — so the take call itself is the
        // await's (unit) value.
        if canonical_hir_name(value_type.name) == "unit" {
            return invoke
        }
        // value$.push(taken$())
        let value: string = self.fresh_name("value_")
        self.slot_decls.push(
            self.slot_declaration(value, value_type, node))
        self.emit(self.slot_push(value, invoke, node))
        return self.slot_take(value, node)
    }

    fn decompose_short_circuit(node: AstNode) -> AstNode {
        let left: AstNode = self.decompose(node.children[0])
        let flag: string = self.fresh_name("short_")
        self.slot_decls.push(self.slot_declaration(
            flag, new HirType("bool"), node))
        self.emit_slot_push(flag, new HirType("bool"), left, node)
        let right_state: int = self.new_state(node)
        let join_state: int = self.new_state(node)
        var condition: AstNode = self.slot_read(flag, node)
        if node.value == "||" {
            let negate: AstNode = self.node("unary", "!", node)
            negate.add(condition)
            condition = negate
        }
        self.emit_state_branch(
            condition, right_state, join_state, node)
        self.enter_state(right_state)
        let right: AstNode = self.decompose(node.children[1])
        self.emit(self.slot_clear(flag, node))
        self.emit_slot_push(flag, new HirType("bool"), right, node)
        self.emit_transition(join_state, node)
        self.enter_state(join_state)
        return self.slot_take(flag, node)
    }

    // `E?` in an async body: the poll closure returns int, so propagation
    // is spelled out — match the value, complete with the failure, or
    // continue with the payload.
    fn rewrite_try(node: AstNode, operand: AstNode) -> AstNode {
        let operand_type: HirType = self.checked_type(node.children[0])
        let payload: HirType = self.checked_type(node)
        let out: string = self.fresh_name("ok_")
        self.slot_decls.push(
            self.slot_declaration(out, payload, node))
        let good_name: string =
            if operand_type.name == "Option" { "some" } else { "ok" }
        let bad_name: string =
            if operand_type.name == "Option" { "none" } else { "err" }
        let good_binding: string = self.fresh_name("v")
        let bad_binding: string = self.fresh_name("e")
        let dispatch: AstNode = self.node("match", "", node)
        dispatch.add(operand)
        let good_arm: AstNode = self.node("arm", "", node)
        let good_pattern: AstNode =
            self.node("pattern_name", good_name, node)
        good_pattern.add(
            self.node("pattern_binding", good_binding, node))
        good_arm.add(good_pattern)
        let good_block: AstNode = self.node("block", "", node)
        good_block.add(self.slot_push(
            out, self.name_of(good_binding, node), node))
        good_arm.add(good_block)
        dispatch.add(good_arm)
        let bad_arm: AstNode = self.node("arm", "", node)
        let bad_pattern: AstNode =
            self.node("pattern_name", bad_name, node)
        if bad_name == "err" {
            bad_pattern.add(
                self.node("pattern_binding", bad_binding, node))
        }
        bad_arm.add(bad_pattern)
        let bad_block: AstNode = self.node("block", "", node)
        self.append_defer_flushes(bad_block, node)
        var failure: AstNode = self.name_of("none", node)
        if bad_name == "err" {
            let rebuilt: AstNode = self.node("call", "", node)
            rebuilt.add(self.name_of("err", node))
            rebuilt.add(self.name_of(bad_binding, node))
            failure = rebuilt
        }
        if !self.body_is_unit {
            let carry: string = self.fresh_name("carry_")
            let declaration: AstNode = self.node("let", carry, node)
            declaration.add(self.type_ast(
                self.function.body_result, node))
            declaration.add(failure)
            bad_block.add(declaration)
            let taken: AstNode = self.node("unary", "move", node)
            taken.add(self.name_of(carry, node))
            let store: AstNode = self.call_method(
                self.name_of("result$", node), "push",
                [taken], node)
            bad_block.add(self.statement_of(store))
        }
        // the early error exit completes through the shared cleanup
        // state like every other completion
        bad_block.add(self.set_state_statement(
            self.cleanup_state, node))
        bad_block.add(self.node("continue", "", node))
        bad_arm.add(bad_block)
        dispatch.add(bad_arm)
        self.emit(self.statement_of(dispatch))
        return self.slot_take(out, node)
    }

    // ---- statement rewriting -----------------------------------------

    fn rewrite_block_statements(block: AstNode) {
        for statement: AstNode in block.children {
            self.rewrite_statement(statement)
        }
    }

    fn rewrite_block(block: AstNode) {
        self.push_scope()
        self.rewrite_block_statements(block)
        self.pop_scope(true, block)
    }

    fn rewrite_statement(statement: AstNode) {
        if !ast_contains_await(statement) &&
           !self.statement_needs_rewrite(statement) {
            self.emit_with_piece_bindings(statement)
            return
        }
        // Control flow that only touches slotted names — no await, no
        // return, no break for an enclosing rewritten loop, no `?` — is
        // still one synchronous statement: substitute the names and emit
        // it whole. Splitting it into states would strand plain locals
        // declared in the current state from uses inside the branches.
        if (statement.kind == "if" || statement.kind == "for" ||
            statement.kind == "match" ||
            (statement.kind == "expression" &&
             statement.children[0].kind == "match")) &&
           !ast_contains_await(statement) &&
           !self.contains_completion(statement) &&
           !(self.loop_stack.len() != 0 &&
             self.contains_loop_exit(statement)) &&
           !self.contains_try(statement) {
            self.emit_with_piece_bindings(statement)
            return
        }
        if statement.kind == "let" || statement.kind == "var" {
            self.rewrite_local(statement)
            return
        }
        if statement.kind == "return" {
            var value: Option<AstNode> = none
            if statement.children.len() != 0 {
                value = some(self.decompose(statement.children[0]))
            }
            self.emit_completion(value, statement)
            return
        }
        if statement.kind == "expression" {
            let inner: AstNode = statement.children[0]
            // A match in statement position produces no value: block arms
            // push nothing, so the value path's pick slot would stay empty
            // and the join's take would blow up.
            if inner.kind == "match" {
                self.decompose_match(
                    inner, none, poison_hir_type())
                return
            }
            let rewritten: AstNode =
                self.decompose(inner)
            self.emit(self.statement_of(rewritten))
            return
        }
        if statement.kind == "assign" {
            self.rewrite_assign(statement)
            return
        }
        if statement.kind == "if" {
            self.rewrite_if(statement)
            return
        }
        if statement.kind == "for" {
            self.rewrite_for(statement)
            return
        }
        if statement.kind == "match" {
            self.decompose_match(statement, none, poison_hir_type())
            return
        }
        if statement.kind == "defer" {
            self.rewrite_defer(statement)
            return
        }
        if statement.kind == "unsafe" {
            // Rewriting may split states, which would strand one wrapper,
            // so each rewritten piece is wrapped alone.
            for child: AstNode in statement.children[0].children {
                if ast_contains_await(child) ||
                   self.statement_needs_rewrite(child) {
                    self.rewrite_statement(child)
                } else {
                    let solo: AstNode = self.node("unsafe", "", child)
                    let solo_block: AstNode =
                        self.node("block", "", child)
                    solo_block.add(self.substitute(child))
                    solo.add(solo_block)
                    self.emit(solo)
                }
            }
            return
        }
        if statement.kind == "break" || statement.kind == "continue" {
            self.rewrite_loop_exit(statement)
            return
        }
        self.fail(
            statement,
            "internal: async expander cannot rewrite statement '{statement.kind}'")
    }

    fn statement_needs_rewrite(node: AstNode) -> bool {
        // an async let always lowers: the child task lives in a slot even
        // when nothing after it suspends
        if (node.kind == "let" || node.kind == "var") &&
           node.note == "async" {
            return true
        }
        if self.contains_completion(node) { return true }
        if self.loop_stack.len() != 0 &&
           self.contains_loop_exit(node) {
            return true
        }
        if self.contains_try(node) { return true }
        if (node.kind == "let" || node.kind == "var") &&
           self.local_needs_slot(node) {
            return true
        }
        var referenced: Map<string, bool> = {}
        ast_names_in(node, inout referenced)
        for name: string in referenced.keys() {
            if self.find_slot(name).is_some() { return true }
        }
        return false
    }

    // return and defer anywhere in the statement (closures excluded)
    // force the completion protocol, however deeply they sit.
    fn contains_completion(node: AstNode) -> bool {
        if node.kind == "return" || node.kind == "defer" {
            return true
        }
        if node.kind == "closure" { return false }
        for child: AstNode in node.children {
            if self.contains_completion(child) { return true }
        }
        return false
    }

    // break/continue that would leave a state-machine loop. Nested loops
    // inside the statement keep their own exits, so the scan stops there.
    fn contains_loop_exit(node: AstNode) -> bool {
        if node.kind == "break" || node.kind == "continue" {
            return true
        }
        if node.kind == "closure" || node.kind == "for" {
            return false
        }
        for child: AstNode in node.children {
            if self.contains_loop_exit(child) { return true }
        }
        return false
    }

    fn contains_try(node: AstNode) -> bool {
        if node.kind == "try" { return true }
        if node.kind == "closure" { return false }
        for child: AstNode in node.children {
            if self.contains_try(child) { return true }
        }
        return false
    }

    fn local_needs_slot(node: AstNode) -> bool {
        if node.note == "async_hoist" { return true }
        if self.defer_names.contains_key(node.value) { return true }
        return false
    }

    fn rewrite_local(statement: AstNode) {
        var declared: HirType = poison_hir_type()
        var value: Option<AstNode> = none
        for child: AstNode in statement.children {
            if child.kind == "type" || child.kind == "array_type" ||
               child.kind == "fn_type" {
                declared = hir_type_from_ast(child)
            } else {
                value = some(child)
            }
        }
        if statement.note == "async" {
            // async let: the child task starts here and lives in the
            // binding's slot. The one await drains it; a scope exit with
            // the task still in the slot cancels it (Task.deinit runs the
            // armed cleanup, children cascade).
            let task_type: HirType = hir_named(
                async_rt_symbol("Task"), [declared])
            match value {
                some(initializer) => {
                    // Interpolated pieces and thread closures in the
                    // arguments resolve names by binding, not through the
                    // slot substitution, so slotted names (a loop
                    // binding, say) re-bind as borrows around the push —
                    // the same wrap every other statement gets.
                    var names: Map<string, bool> = {}
                    self.interpolated_slot_names(
                        initializer, inout names)
                    self.thread_capture_slot_names(
                        initializer, inout names)
                    var wrap_slots: List<AsyncSlot> = []
                    for name: string in names.keys() {
                        match self.find_slot(name) {
                            some(borrowed) => {
                                wrap_slots.push(borrowed)
                            }
                            none => {}
                        }
                    }
                    if wrap_slots.len() != 0 {
                        self.push_scope()
                        for borrowed: AsyncSlot in wrap_slots {
                            let mask: AsyncSlot = new AsyncSlot(
                                borrowed.name, "", borrowed.type)
                            mask.masked = true
                            let top: AsyncScope =
                                self.scopes[self.scopes.len() - 1]
                            top.bindings[borrowed.name] = mask
                        }
                        let rewritten: AstNode = self.readiness_swap(
                            self.decompose(initializer))
                        self.pop_scope(false, statement)
                        let slot: AsyncSlot = self.declare_slot(
                            statement.value, task_type, statement)
                        slot.is_child = true
                        let carry: string = self.fresh_name("carry_")
                        let carry_decl: AstNode = self.node(
                            "let", carry, statement)
                        carry_decl.add(
                            self.type_ast(task_type, statement))
                        carry_decl.add(rewritten)
                        let taken: AstNode = self.node(
                            "unary", "move", statement)
                        taken.add(self.name_of(carry, statement))
                        var wrapped: AstNode = self.node(
                            "block", "", statement)
                        wrapped.add(carry_decl)
                        wrapped.add(self.slot_push(
                            slot.slot, taken, statement))
                        var index: int = wrap_slots.len() - 1
                        for index >= 0 {
                            let borrowed: AsyncSlot = wrap_slots[index]
                            let loop_node: AstNode = self.node(
                                "for", borrowed.name, statement)
                            let binding: AstNode = self.node(
                                "binding", borrowed.name, statement)
                            binding.add(self.type_ast(
                                borrowed.type, statement))
                            loop_node.add(binding)
                            loop_node.add(self.name_of(
                                borrowed.slot, statement))
                            if wrapped.kind == "block" {
                                loop_node.add(wrapped)
                            } else {
                                let body: AstNode = self.node(
                                    "block", "", statement)
                                body.add(wrapped)
                                loop_node.add(body)
                            }
                            wrapped = loop_node
                            index -= 1
                        }
                        self.emit(wrapped)
                        return
                    }
                    let rewritten: AstNode = self.readiness_swap(
                        self.decompose(initializer))
                    let slot: AsyncSlot = self.declare_slot(
                        statement.value, task_type, statement)
                    slot.is_child = true
                    self.emit_slot_push(
                        slot.slot, task_type, rewritten, statement)
                }
                none => {}
            }
            return
        }
        if !self.local_needs_slot(statement) {
            match value {
                some(initializer) => {
                    let rewritten: AstNode =
                        self.decompose(initializer)
                    let fresh: AstNode = self.node(
                        statement.kind, statement.value, statement)
                    for child: AstNode in statement.children {
                        if child.kind == "type" ||
                           child.kind == "array_type" ||
                           child.kind == "fn_type" {
                            fresh.add(child)
                        }
                    }
                    fresh.add(rewritten)
                    self.emit(fresh)
                }
                none => { self.emit(statement) }
            }
            return
        }
        match value {
            some(initializer) => {
                // A thread closure in the initializer must capture Send
                // values, never a suspended local's one-slot List: those
                // names re-bind as plain borrows around the push.
                var captures: Map<string, bool> = {}
                self.thread_capture_slot_names(
                    initializer, inout captures)
                if captures.len() != 0 {
                    var wrap_slots: List<AsyncSlot> = []
                    for name: string in captures.keys() {
                        match self.find_slot(name) {
                            some(borrowed) => {
                                wrap_slots.push(borrowed)
                            }
                            none => {}
                        }
                    }
                    self.push_scope()
                    for borrowed: AsyncSlot in wrap_slots {
                        let mask: AsyncSlot = new AsyncSlot(
                            borrowed.name, "", borrowed.type)
                        mask.masked = true
                        let top: AsyncScope =
                            self.scopes[self.scopes.len() - 1]
                        top.bindings[borrowed.name] = mask
                    }
                    let rebound: AstNode =
                        self.substitute(initializer)
                    self.pop_scope(false, statement)
                    let target: AsyncSlot = self.declare_slot(
                        statement.value, declared, statement)
                    let carry: string = self.fresh_name("carry_")
                    let carry_decl: AstNode = self.node(
                        "let", carry, statement)
                    carry_decl.add(
                        self.type_ast(declared, statement))
                    carry_decl.add(rebound)
                    let taken: AstNode = self.node(
                        "unary", "move", statement)
                    taken.add(self.name_of(carry, statement))
                    var wrapped: AstNode = self.node(
                        "block", "", statement)
                    wrapped.add(carry_decl)
                    wrapped.add(self.slot_push(
                        target.slot, taken, statement))
                    var index: int = wrap_slots.len() - 1
                    for index >= 0 {
                        let borrowed: AsyncSlot = wrap_slots[index]
                        let loop_node: AstNode = self.node(
                            "for", borrowed.name, statement)
                        let binding: AstNode = self.node(
                            "binding", borrowed.name, statement)
                        binding.add(self.type_ast(
                            borrowed.type, statement))
                        loop_node.add(binding)
                        loop_node.add(self.name_of(
                            borrowed.slot, statement))
                        if wrapped.kind == "block" {
                            loop_node.add(wrapped)
                        } else {
                            let body: AstNode = self.node(
                                "block", "", statement)
                            body.add(wrapped)
                            loop_node.add(body)
                        }
                        wrapped = loop_node
                        index -= 1
                    }
                    self.emit(wrapped)
                    return
                }
                let rewritten: AstNode = self.decompose(initializer)
                let slot: AsyncSlot = self.declare_slot(
                    statement.value, declared, statement)
                self.emit_slot_push(
                    slot.slot, declared, rewritten, statement)
            }
            none => {
                let slot: AsyncSlot = self.declare_slot(
                    statement.value, declared, statement)
                let ignored: string = slot.slot
            }
        }
    }

    fn rewrite_assign(statement: AstNode) {
        let target: AstNode = statement.children[0]
        var value: AstNode = statement.children[1]
        if statement.value != "=" {
            let operation: string =
                statement.value.slice(0, statement.value.len() - 1)
            let combined: AstNode =
                self.node("binary", operation, statement)
            combined.add(target)
            combined.add(value)
            value = combined
        }
        if target.kind == "name" {
            match self.find_slot(target.value) {
                some(slot) => {
                    // The right side evaluates before the old value drops,
                    // matching ordinary assignment order.
                    let rewritten: AstNode = self.decompose(value)
                    let carry: string = self.fresh_name("carry_")
                    let declaration: AstNode =
                        self.node("let", carry, statement)
                    declaration.add(self.type_ast(slot.type, statement))
                    declaration.add(rewritten)
                    self.emit(declaration)
                    self.emit(self.slot_clear(slot.slot, statement))
                    let taken: AstNode =
                        self.node("unary", "move", statement)
                    taken.add(self.name_of(carry, statement))
                    self.emit(self.slot_push(
                        slot.slot, taken, statement))
                    return
                }
                none => {}
            }
        }
        let rewritten_value: AstNode = self.decompose(value)
        let rewritten_target: AstNode = self.substitute(target)
        let fresh: AstNode =
            self.node("assign", "=", statement)
        fresh.add(rewritten_target)
        fresh.add(rewritten_value)
        self.emit(fresh)
    }

    fn rewrite_if(statement: AstNode) {
        let condition: AstNode = self.decompose(statement.children[0])
        let then_state: int = self.new_state(statement)
        let else_state: int = self.new_state(statement)
        let join_state: int = self.new_state(statement)
        self.emit_state_branch(
            condition, then_state, else_state, statement)
        self.enter_state(then_state)
        self.rewrite_block(statement.children[1])
        self.emit_transition(join_state, statement)
        self.enter_state(else_state)
        if statement.children.len() > 2 {
            if statement.children[2].kind == "block" {
                self.rewrite_block(statement.children[2])
            } else {
                self.push_scope()
                self.rewrite_statement(statement.children[2])
                self.pop_scope(true, statement)
            }
        }
        self.emit_transition(join_state, statement)
        self.enter_state(join_state)
    }

    fn decompose_if_value(node: AstNode, out: string,
                          out_type: HirType) {
        let condition: AstNode = self.decompose(node.children[0])
        let then_state: int = self.new_state(node)
        let else_state: int = self.new_state(node)
        let join_state: int = self.new_state(node)
        self.emit_state_branch(
            condition, then_state, else_state, node)
        self.enter_state(then_state)
        let then_value: AstNode =
            self.decompose(self.branch_value(node.children[1]))
        self.emit_slot_push(out, out_type, then_value, node)
        self.emit_transition(join_state, node)
        self.enter_state(else_state)
        let else_value: AstNode =
            self.decompose(self.branch_value(node.children[2]))
        self.emit_slot_push(out, out_type, else_value, node)
        self.emit_transition(join_state, node)
        self.enter_state(join_state)
    }

    fn branch_value(node: AstNode) -> AstNode {
        if node.kind == "block" {
            let inner: AstNode = node.children[0]
            if inner.kind == "expression" {
                return inner.children[0]
            }
            return inner
        }
        return node
    }

    fn decompose_match(node: AstNode, out: Option<string>,
                       out_type: HirType) {
        let scrutinee: AstNode = self.decompose(node.children[0])
        let scrutinee_type: HirType =
            self.checked_type(node.children[0])
        let keep: string = self.fresh_name("subject_")
        self.slot_decls.push(
            self.slot_declaration(keep, scrutinee_type, node))
        self.emit_slot_push(keep, scrutinee_type, scrutinee, node)
        let join_state: int = self.new_state(node)
        let dispatch: AstNode = self.node("match", "", node)
        dispatch.add(self.slot_read(keep, node))
        var arm_states: List<int> = []
        var arm_slot_names: List<AsyncArmSlots> = []
        var arm_index: int = 1
        for arm_index < node.children.len() {
            let arm: AstNode = node.children[arm_index]
            let arm_state: int = self.new_state(node)
            arm_states.push(arm_state)
            let pattern: AstNode = arm.children[0]
            var binding_names: List<string> = []
            self.collect_pattern_bindings(
                pattern, inout binding_names)
            let slot_names: AsyncArmSlots = new AsyncArmSlots()
            for binding: string in binding_names {
                slot_names.names.push(
                    self.fresh_name("{binding}_arm"))
            }
            let jump_arm: AstNode = self.node("arm", "", arm)
            jump_arm.add(pattern)
            let jump_block: AstNode = self.node("block", "", arm)
            var binding_index: int = 0
            for binding: string in binding_names {
                let slot_name: string = slot_names.names[binding_index]
                jump_block.add(self.statement_of(self.call_method(
                    self.name_of(slot_name, arm), "clear", [], arm)))
                jump_block.add(self.statement_of(self.call_method(
                    self.name_of(slot_name, arm), "push",
                    [self.name_of(binding, arm)], arm)))
                binding_index += 1
            }
            jump_block.add(
                self.set_state_statement(arm_state, arm))
            jump_arm.add(jump_block)
            dispatch.add(jump_arm)
            arm_slot_names.push(slot_names)
            arm_index += 1
        }
        self.emit(self.statement_of(dispatch))
        self.emit(self.slot_clear(keep, node))
        self.emit(self.node("continue", "", node))
        arm_index = 1
        var cursor: int = 0
        for arm_index < node.children.len() {
            let arm: AstNode = node.children[arm_index]
            self.enter_state(arm_states[cursor])
            self.push_scope()
            let pattern: AstNode = arm.children[0]
            var binding_names: List<string> = []
            self.collect_pattern_bindings(
                pattern, inout binding_names)
            var binding_index: int = 0
            for binding: string in binding_names {
                let binding_type: HirType =
                    self.binding_type_of(pattern, binding)
                let slot: AsyncSlot = new AsyncSlot(
                    binding,
                    arm_slot_names[cursor].names[binding_index],
                    binding_type)
                self.slot_decls.push(self.slot_declaration(
                    slot.slot, binding_type, arm))
                self.scopes[self.scopes.len() - 1].bindings[binding] = slot
                self.scopes[self.scopes.len() - 1].order.push(binding)
                binding_index += 1
            }
            let body: AstNode = arm.children[1]
            if body.kind == "block" {
                self.rewrite_block_statements(body)
            } else {
                match out {
                    some(destination) => {
                        let value: AstNode = self.decompose(body)
                        self.emit_slot_push(
                            destination, out_type, value, arm)
                    }
                    none => {
                        let value: AstNode = self.decompose(body)
                        self.emit(self.statement_of(value))
                    }
                }
            }
            self.pop_scope(true, arm)
            self.emit_transition(join_state, arm)
            arm_index += 1
            cursor += 1
        }
        self.enter_state(join_state)
    }

    fn collect_pattern_bindings(pattern: AstNode,
                                inout names: List<string>) {
        if pattern.kind == "pattern_binding" {
            names.push(pattern.value)
            return
        }
        for child: AstNode in pattern.children {
            self.collect_pattern_bindings(child, inout names)
        }
    }

    fn binding_type_of(pattern: AstNode, binding: string) -> HirType {
        if pattern.kind == "pattern_binding" &&
           pattern.value == binding {
            match pattern.checked {
                some(lowered) => { return lowered.type }
                none => {}
            }
        }
        for child: AstNode in pattern.children {
            let found: HirType =
                self.binding_type_of(child, binding)
            if found.name != "poison" { return found }
        }
        return poison_hir_type()
    }

    fn rewrite_for(statement: AstNode) {
        if statement.children.len() == 1 {
            let head: int = self.new_state(statement)
            let exit: int = self.new_state(statement)
            self.emit_transition(head, statement)
            self.enter_state(head)
            self.loop_stack.push(new AsyncLoopContext(head, exit))
            self.push_scope()
            self.rewrite_block_statements(statement.children[0])
            self.pop_scope(true, statement)
            self.loop_stack.pop()
            self.emit_transition(head, statement)
            self.enter_state(exit)
            return
        }
        if statement.children.len() == 2 {
            let head: int = self.new_state(statement)
            let body_state: int = self.new_state(statement)
            let exit: int = self.new_state(statement)
            self.emit_transition(head, statement)
            self.enter_state(head)
            let condition: AstNode =
                self.decompose(statement.children[0])
            self.emit_state_branch(
                condition, body_state, exit, statement)
            self.enter_state(body_state)
            self.loop_stack.push(new AsyncLoopContext(head, exit))
            self.push_scope()
            self.rewrite_block_statements(statement.children[1])
            self.pop_scope(true, statement)
            self.loop_stack.pop()
            self.emit_transition(head, statement)
            self.enter_state(exit)
            return
        }
        let binding: AstNode = statement.children[0]
        let iterable: AstNode = statement.children[1]
        let iterable_type: HirType = self.checked_type(iterable)
        let element_type: HirType =
            match binding.checked {
                some(lowered) => lowered.type,
                none => poison_hir_type(),
            }
        if iterable_type.name == "range" {
            self.rewrite_range_for(
                statement, binding, iterable, element_type)
            return
        }
        if iterable_type.name == "List" ||
           iterable_type.name == "array" {
            self.rewrite_list_for(
                statement, binding, iterable, element_type)
            return
        }
        self.fail(
            statement,
            "internal: async expander cannot rewrite a loop over {iterable_type.name}")
    }

    fn rewrite_range_for(statement: AstNode, binding: AstNode,
                         iterable: AstNode, element_type: HirType) {
        // The bound and the counter live in slots; the range value itself
        // is never materialized.
        let lower: AstNode = self.decompose(iterable.children[0])
        let cursor: string = self.fresh_name("cursor_")
        self.slot_decls.push(self.slot_declaration(
            cursor, element_type, statement))
        self.emit(self.slot_clear(cursor, statement))
        self.emit_slot_push(cursor, element_type, lower, statement)
        let upper: AstNode = self.decompose(iterable.children[1])
        let limit: string = self.fresh_name("limit_")
        self.slot_decls.push(self.slot_declaration(
            limit, element_type, statement))
        self.emit(self.slot_clear(limit, statement))
        self.emit_slot_push(limit, element_type, upper, statement)
        let head: int = self.new_state(statement)
        let body_state: int = self.new_state(statement)
        let advance: int = self.new_state(statement)
        let exit: int = self.new_state(statement)
        self.emit_transition(head, statement)
        self.enter_state(head)
        let compare: AstNode = self.node(
            "binary",
            if iterable.value == "..=" { "<=" } else { "<" },
            statement)
        compare.add(self.slot_read(cursor, statement))
        compare.add(self.slot_read(limit, statement))
        self.emit_state_branch(compare, body_state, exit, statement)
        self.enter_state(body_state)
        self.loop_stack.push(new AsyncLoopContext(advance, exit))
        self.push_scope()
        let slot: AsyncSlot = self.declare_slot(
            binding.value, element_type, statement)
        self.emit(self.slot_clear(slot.slot, statement))
        self.emit(self.slot_push(
            slot.slot, self.slot_read(cursor, statement), statement))
        self.rewrite_block_statements(statement.children[2])
        self.pop_scope(true, statement)
        self.loop_stack.pop()
        self.emit_transition(advance, statement)
        self.enter_state(advance)
        let bumped: AstNode = self.node("binary", "+", statement)
        bumped.add(self.slot_read(cursor, statement))
        bumped.add(self.int_literal(1, statement))
        let stored: string = self.fresh_name("bump_")
        let bump_decl: AstNode = self.node("let", stored, statement)
        bump_decl.add(self.type_ast(element_type, statement))
        bump_decl.add(bumped)
        self.emit(bump_decl)
        self.emit(self.slot_clear(cursor, statement))
        self.emit(self.slot_push(
            cursor, self.name_of(stored, statement), statement))
        self.emit_transition(head, statement)
        self.enter_state(exit)
        self.emit(self.slot_clear(cursor, statement))
        self.emit(self.slot_clear(limit, statement))
    }

    fn rewrite_list_for(statement: AstNode, binding: AstNode,
                        iterable: AstNode, element_type: HirType) {
        // Owned iteration by index: the element is copied into the
        // binding's slot each turn, so nothing borrows the list across a
        // suspension. The checker already refused loops whose element is
        // move-only.
        let source: AstNode = self.decompose(iterable)
        var list_place: AstNode = source
        var list_slot: string = ""
        if !ast_is_pure_place(source) {
            let iterable_type: HirType = self.checked_type(iterable)
            list_slot = self.fresh_name("iter_")
            self.slot_decls.push(self.slot_declaration(
                list_slot, iterable_type, statement))
            self.emit_slot_push(
                list_slot, self.checked_type(iterable), source,
                statement)
            list_place = self.slot_read(list_slot, statement)
        }
        let index_name: string = self.fresh_name("index_")
        self.slot_decls.push(self.slot_declaration(
            index_name, new HirType("int"), statement))
        self.emit(self.slot_clear(index_name, statement))
        self.emit(self.slot_push(
            index_name, self.int_literal(0, statement), statement))
        let head: int = self.new_state(statement)
        let body_state: int = self.new_state(statement)
        let advance: int = self.new_state(statement)
        let exit: int = self.new_state(statement)
        self.emit_transition(head, statement)
        self.enter_state(head)
        let compare: AstNode = self.node("binary", "<", statement)
        compare.add(self.slot_read(index_name, statement))
        compare.add(self.call_method(list_place, "len", [], statement))
        self.emit_state_branch(compare, body_state, exit, statement)
        self.enter_state(body_state)
        self.loop_stack.push(new AsyncLoopContext(advance, exit))
        self.push_scope()
        let slot: AsyncSlot = self.declare_slot(
            binding.value, element_type, statement)
        let element: AstNode = self.node("index", "", statement)
        element.add(list_place)
        element.add(self.slot_read(index_name, statement))
        self.emit(self.slot_clear(slot.slot, statement))
        self.emit(self.slot_push(slot.slot, element, statement))
        self.rewrite_block_statements(statement.children[2])
        self.pop_scope(true, statement)
        self.loop_stack.pop()
        self.emit_transition(advance, statement)
        self.enter_state(advance)
        let bumped: AstNode = self.node("binary", "+", statement)
        bumped.add(self.slot_read(index_name, statement))
        bumped.add(self.int_literal(1, statement))
        let stored: string = self.fresh_name("bump_")
        let bump_decl: AstNode = self.node("let", stored, statement)
        let int_type: AstNode = self.node("type", "int", statement)
        int_type.resolved = "int"
        bump_decl.add(int_type)
        bump_decl.add(bumped)
        self.emit(bump_decl)
        self.emit(self.slot_clear(index_name, statement))
        self.emit(self.slot_push(
            index_name, self.name_of(stored, statement), statement))
        self.emit_transition(head, statement)
        self.enter_state(exit)
        self.emit(self.slot_clear(index_name, statement))
        if list_slot != "" {
            self.emit(self.slot_clear(list_slot, statement))
        }
    }

    fn rewrite_loop_exit(statement: AstNode) {
        // Both exits leave the iteration early, skipping the body-end
        // clears, so both clear this loop's slots here: a value from
        // iteration N must never sit under iteration N+1's push, and a
        // pending child from iteration N cancels at its own continue.
        let context: AsyncLoopContext =
            self.loop_stack[self.loop_stack.len() - 1]
        for slot: string in context.slots_inside {
            self.emit(self.slot_clear(slot, statement))
        }
        if statement.kind == "break" {
            self.emit_transition(context.exit_state, statement)
        } else {
            self.emit_transition(context.continue_state, statement)
        }
    }

    fn rewrite_defer(statement: AstNode) {
        let flag: string = self.fresh_name("armed_")
        let declaration: AstNode = self.node("var", flag, statement)
        let bool_type: AstNode = self.node("type", "bool", statement)
        bool_type.resolved = "bool"
        declaration.add(bool_type)
        declaration.add(self.bool_literal(false, statement))
        self.slot_decls.push(declaration)
        let body: AstNode = self.wrap_for_pieces(
            self.statement_of(statement.children[0]))
        self.defers.push(new AsyncDefer(flag, body))
        self.emit(self.assign_statement(
            self.name_of(flag, statement),
            self.bool_literal(true, statement), statement))
    }

    fn append_defer_flushes(block: AstNode, anchor: AstNode) {
        var index: int = self.defers.len() - 1
        for index >= 0 {
            let armed: AsyncDefer = self.defers[index]
            let guard: AstNode = self.node("if", "", anchor)
            guard.add(self.name_of(armed.flag, anchor))
            let run: AstNode = self.node("block", "", anchor)
            run.add(self.assign_statement(
                self.name_of(armed.flag, anchor),
                self.bool_literal(false, anchor), anchor))
            run.add(armed.body)
            guard.add(run)
            block.add(guard)
            index -= 1
        }
    }

    fn emit_completion(value: Option<AstNode>, anchor: AstNode) {
        let flush: AstNode = self.node("block", "", anchor)
        self.append_defer_flushes(flush, anchor)
        for flushed: AstNode in flush.children {
            self.emit(flushed)
        }
        match value {
            some(result_value) => {
                if self.body_is_unit {
                    self.emit(self.statement_of(result_value))
                } else {
                    self.emit_slot_push(
                        "result$", self.function.body_result,
                        result_value, anchor)
                }
            }
            none => {}
        }
        // Every remaining slot clears in the shared cleanup state, last
        // created first — after the result push above, which may still
        // read them. Without this the values would drop when the task
        // record's closures release, in whatever capture order each
        // backend happened to emit; the cleanup state is built once the
        // full slot list is known, so every completion site — even one
        // emitted before a later slot existed — clears everything, and
        // the drop order is defined and the same everywhere.
        self.emit_transition(self.cleanup_state, anchor)
    }

    // ---- hoist pre-pass ----------------------------------------------

    fn mark_hoists(block: AstNode, awaits_after_block: bool) {
        var seen_after: bool = awaits_after_block
        var index: int = block.children.len() - 1
        for index >= 0 {
            let statement: AstNode = block.children[index]
            if (statement.kind == "let" ||
                statement.kind == "var") && seen_after &&
               statement.note != "async" {
                // an async let is always slotted by its own lowering; the
                // marker must survive for rewrite_local to see it
                statement.note = "async_hoist"
            }
            if statement.kind == "if" {
                self.mark_hoists(statement.children[1], seen_after)
                if statement.children.len() > 2 &&
                   statement.children[2].kind == "block" {
                    self.mark_hoists(
                        statement.children[2], seen_after)
                }
            }
            if statement.kind == "for" {
                let loops_await: bool =
                    ast_contains_await(statement)
                let body: AstNode =
                    statement.children[
                        statement.children.len() - 1]
                if body.kind == "block" {
                    self.mark_hoists(
                        body, seen_after || loops_await)
                }
            }
            if statement.kind == "match" {
                var arm: int = 1
                for arm < statement.children.len() {
                    let arm_node: AstNode =
                        statement.children[arm]
                    if arm_node.children.len() > 1 &&
                       arm_node.children[1].kind == "block" {
                        self.mark_hoists(
                            arm_node.children[1], seen_after)
                    }
                    arm += 1
                }
            }
            if statement.kind == "unsafe" {
                self.mark_hoists(
                    statement.children[0], seen_after)
            }
            if ast_contains_await(statement) {
                seen_after = true
            }
            index -= 1
        }
    }

    fn collect_defer_names(node: AstNode) {
        if node.kind == "defer" {
            var found: Map<string, bool> = {}
            ast_names_in(node.children[0], inout found)
            for name: string in found.keys() {
                self.defer_names[name] = true
            }
        }
        for child: AstNode in node.children {
            self.collect_defer_names(child)
        }
    }

    // ---- driving -----------------------------------------------------

    fn expand_function(function: HirFunction) {
        self.function = function
        self.states = []
        self.slot_decls = []
        self.slot_names = []
        self.scopes = []
        self.defer_names = {}
        self.defers = []
        self.loop_stack = []
        self.counter = 0
        self.body_is_unit =
            canonical_hir_name(function.body_result.name) == "unit"
        var body: Option<AstNode> = none
        for child: AstNode in function.syntax.children {
            if child.kind == "block" { body = some(child) }
        }
        let anchor: AstNode = function.syntax
        var body_block: AstNode = self.node("block", "", anchor)
        match body {
            some(block) => { body_block = block }
            none => {}
        }
        self.collect_defer_names(body_block)
        self.mark_hoists(body_block, false)
        self.push_scope()
        // Move parameters are owned locals of the maker; the body may move
        // them onward, which a captured local cannot do, so they live in
        // slots from the start.
        var param_pushes: List<AstNode> = []
        for parameter: HirParameter in function.parameters {
            if parameter.passing != "move" { continue }
            let slot: AsyncSlot = self.declare_slot(
                parameter.name, parameter.type, anchor)
            let taken: AstNode = self.node("unary", "move", anchor)
            taken.add(self.name_of(parameter.name, anchor))
            param_pushes.push(self.slot_push(
                slot.slot, taken, anchor))
        }
        let entry: int = self.new_state(anchor)
        self.cleanup_state = self.new_state(anchor)
        self.enter_state(entry)
        self.push_scope()
        self.rewrite_block_statements(body_block)
        self.pop_scope(false, anchor)
        // Falling off the end: a unit body completes; anything else can
        // only get here on a path the stage-0 checker rejects, so panic
        // rather than hand back garbage.
        if self.body_is_unit {
            self.emit_completion(none, anchor)
        } else {
            let complaint: AstNode = self.node("call", "", anchor)
            complaint.add(self.name_of("panic", anchor))
            let message: AstNode = self.node(
                "literal",
                "\"'{function.name}' finished without a return\"",
                anchor)
            message.note = "string"
            complaint.add(message)
            self.emit(self.statement_of(complaint))
            self.emit(self.return_int(1, anchor))
        }
        self.pop_scope(false, anchor)
        // The shared cleanup state: every completion transitions here.
        // The full slot list exists now, so even a completion emitted
        // before a later slot was created clears everything, last
        // created first — the drop order plain locals get.
        self.enter_state(self.cleanup_state)
        var clear_index: int = self.slot_names.len() - 1
        for clear_index >= 0 {
            if self.slot_names[clear_index] != "result$" {
                self.emit(self.slot_clear(
                    self.slot_names[clear_index], anchor))
            }
            clear_index -= 1
        }
        self.emit(self.set_state_statement(0 - 1, anchor))
        self.emit(self.return_int(1, anchor))

        // Assemble the maker body.
        let maker: AstNode = self.node("block", "", anchor)
        for declaration: AstNode in self.slot_decls {
            maker.add(declaration)
        }
        for push: AstNode in param_pushes {
            maker.add(push)
        }
        let state_decl: AstNode = self.node("var", "state$", anchor)
        let int_type: AstNode = self.node("type", "int", anchor)
        int_type.resolved = "int"
        state_decl.add(int_type)
        state_decl.add(self.int_literal(0, anchor))
        maker.add(state_decl)
        if !self.body_is_unit {
            maker.add(self.slot_declaration(
                "result$", function.body_result, anchor))
        }

        // fn() -> int { for { if state$ == K { ... } ... } }
        let poll_closure: AstNode = self.node("closure", "", anchor)
        poll_closure.add(self.node("params", "", anchor))
        let poll_result: AstNode = self.node("result", "", anchor)
        let poll_int: AstNode = self.node("type", "int", anchor)
        poll_int.resolved = "int"
        poll_result.add(poll_int)
        poll_closure.add(poll_result)
        let poll_body: AstNode = self.node("block", "", anchor)
        let dispatch_loop: AstNode = self.node("for", "", anchor)
        let dispatch_body: AstNode = self.node("block", "", anchor)
        var state_id: int = 0
        for state_block: AstNode in self.states {
            let test: AstNode = self.node("if", "", anchor)
            let same: AstNode = self.node("binary", "==", anchor)
            same.add(self.name_of("state$", anchor))
            same.add(self.int_literal(state_id, anchor))
            test.add(same)
            test.add(state_block)
            dispatch_body.add(test)
            state_id += 1
        }
        let finished: AstNode = self.node("if", "", anchor)
        let is_done: AstNode = self.node("binary", "==", anchor)
        is_done.add(self.name_of("state$", anchor))
        is_done.add(self.int_literal(0 - 1, anchor))
        finished.add(is_done)
        let done_block: AstNode = self.node("block", "", anchor)
        done_block.add(self.return_int(1, anchor))
        finished.add(done_block)
        dispatch_body.add(finished)
        let bad_state: AstNode = self.node("call", "", anchor)
        bad_state.add(self.name_of("panic", anchor))
        let bad_message: AstNode = self.node(
            "literal", "\"internal: bad async task state\"", anchor)
        bad_message.note = "string"
        bad_state.add(bad_message)
        dispatch_body.add(self.statement_of(bad_state))
        dispatch_loop.add(dispatch_body)
        poll_body.add(dispatch_loop)
        poll_closure.add(poll_body)

        // fn() -> R { return result$.remove(0) } — or fn() {} for unit
        let take_closure: AstNode = self.node("closure", "", anchor)
        take_closure.add(self.node("params", "", anchor))
        if !self.body_is_unit {
            let take_result: AstNode = self.node("result", "", anchor)
            take_result.add(
                self.type_ast(function.body_result, anchor))
            take_closure.add(take_result)
            let take_body: AstNode = self.node("block", "", anchor)
            let take_return: AstNode = self.node("return", "", anchor)
            take_return.add(self.slot_take("result$", anchor))
            take_body.add(take_return)
            take_closure.add(take_body)
        } else {
            take_closure.add(self.node("block", "", anchor))
        }

        // fn() { armed defers newest first, then every slot clears in
        // reverse creation order — cancellation drops what the body
        // still held in a defined order, children cancelling in cascade
        // as their slots clear, instead of whatever capture order each
        // backend's closure teardown happened to use }
        let cancel_closure: AstNode = self.node("closure", "", anchor)
        cancel_closure.add(self.node("params", "", anchor))
        let cancel_body: AstNode = self.node("block", "", anchor)
        self.append_defer_flushes(cancel_body, anchor)
        var cancel_index: int = self.slot_names.len() - 1
        for cancel_index >= 0 {
            if self.slot_names[cancel_index] != "result$" {
                cancel_body.add(self.slot_clear(
                    self.slot_names[cancel_index], anchor))
            }
            cancel_index -= 1
        }
        cancel_closure.add(cancel_body)

        let task_hir: HirType = hir_named(
            async_rt_symbol("Task"), [function.body_result])
        let task_new: AstNode = self.node("new", "", anchor)
        task_new.add(self.type_ast(task_hir, anchor))
        task_new.add(poll_closure)
        task_new.add(take_closure)
        task_new.add(cancel_closure)
        if function.qualified == self.program.entry_symbol {
            // The entry point cannot hand a task to anyone, so it drives
            // its own: this loop is the hidden executor's root. main keeps
            // the unit result, so the native entry ABI is unchanged.
            let root_decl: AstNode = self.node("let", "root$", anchor)
            root_decl.add(self.type_ast(task_hir, anchor))
            root_decl.add(task_new)
            maker.add(root_decl)
            let drive: AstNode = self.node("for", "", anchor)
            let drive_body: AstNode = self.node("block", "", anchor)
            let poll: AstNode = self.call_method(
                self.name_of("root$", anchor), "poll_once", [], anchor)
            let done: AstNode = self.node("binary", "==", anchor)
            done.add(poll)
            done.add(self.int_literal(1, anchor))
            let leave: AstNode = self.node("if", "", anchor)
            leave.add(done)
            let leave_block: AstNode = self.node("block", "", anchor)
            if self.has_reactor {
                // async main is done: close the reactor and reset the
                // task slots before returning, so one process can run
                // again.
                let shutdown_call: AstNode = self.node("call", "", anchor)
                let shutdown_callee: AstNode = self.node(
                    "name", "driver_shutdown", anchor)
                shutdown_callee.resolved = async_rt_symbol("driver_shutdown")
                shutdown_call.add(shutdown_callee)
                leave_block.add(self.statement_of(shutdown_call))
            }
            leave_block.add(self.node("return", "", anchor))
            leave.add(leave_block)
            drive_body.add(leave)
            if self.has_reactor {
                // Pending means something is parked on readiness: block
                // in the reactor until it can move. Never a busy spin.
                let wait_call: AstNode = self.node("call", "", anchor)
                let wait_callee: AstNode = self.node(
                    "name", "driver_wait", anchor)
                wait_callee.resolved = async_rt_symbol("driver_wait")
                wait_call.add(wait_callee)
                drive_body.add(self.statement_of(wait_call))
            } else {
                // No readiness source exists in this program, so pending
                // after a full poll cycle can never resolve: report the
                // deadlock without ever naming a poller symbol — this is
                // what lets pure async link under every runtime profile.
                let stall_call: AstNode = self.node("call", "", anchor)
                let stall_callee: AstNode = self.node(
                    "name", "driver_stall", anchor)
                stall_callee.resolved = async_rt_symbol("driver_stall")
                stall_call.add(stall_callee)
                drive_body.add(self.statement_of(stall_call))
            }
            drive.add(drive_body)
            maker.add(drive)
        } else {
            let hand_back: AstNode = self.node("return", "", anchor)
            hand_back.add(task_new)
            maker.add(hand_back)
        }

        // Swap the maker in and flip the signature: outside the expander
        // the call had the user-facing result type R (asyncness is an
        // effect), but the maker really returns the internal task. main
        // stays unit — its maker drives the task instead of returning it.
        var fresh_syntax: AstNode = self.node(
            "fn", function.syntax.value, anchor)
        for child: AstNode in function.syntax.children {
            if child.kind != "block" { fresh_syntax.add(child) }
        }
        fresh_syntax.add(maker)
        function.syntax = fresh_syntax
        if function.qualified != self.program.entry_symbol {
            function.result = task_hir
            function.body_result = task_hir
        }
        function.expanded = true
        function.body = []
    }

    fn run() -> bool {
        var any: bool = false
        for function: HirFunction in self.program.functions {
            if function.is_async && !function.expanded &&
               function.has_body {
                self.expand_function(function)
                any = true
            }
        }
        // Bodiless async declarations — interface methods — flip too:
        // their implementations are makers, so the declared signature
        // must agree on returning the task.
        for function: HirFunction in self.program.functions {
            if function.is_async && !function.expanded {
                let task: HirType = hir_named(
                    async_rt_symbol("Task"), [function.body_result])
                function.result = task
                function.body_result = task
                function.expanded = true
            }
        }
        if self.errors.len() != 0 { return false }
        if !any { return true }
        match os.env("BEANS_ASYNC_DUMP") {
            some(_) => {
                for function: HirFunction in
                    self.program.functions {
                    if function.is_async && function.expanded &&
                       function.has_body {
                        io.eprintln(render_ast(function.syntax))
                    }
                }
            }
            none => {}
        }
        // Re-check every rewritten maker with a fresh checker; the maker
        // is ordinary Beans, so any diagnostic here is an expander bug.
        let recheck: ExpressionChecker =
            new ExpressionChecker(self.signature)
        for function: HirFunction in self.program.functions {
            if function.is_async && function.expanded &&
               function.has_body {
                recheck.check_function(function)
            }
        }
        for diagnostic: Diagnostic in recheck.errors {
            self.errors.push(Diagnostic {
                severity: diagnostic.severity,
                file: diagnostic.file,
                line: diagnostic.line,
                col: diagnostic.col,
                message:
                    "internal async expansion error: {diagnostic.message}",
            })
        }
        return self.errors.len() == 0
    }
}
