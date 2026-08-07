// The Beans debugger: a Debug Adapter Protocol server over stdio, driving the
// tree interpreter.
//
// The interpreter already has everything a source-level debugger needs — real
// call frames, values, the binding ids the checker allocated, and a source
// position on every node — so the debugger reads those rather than inventing a
// second model. Breakpoints are Beans file and line positions; frames name
// Beans functions; a local keeps its own binding id, so a shadowed name stays
// two separate variables.
//
// The adapter is single-threaded. While the program runs, the interpreter owns
// the process; at every stop it hands control back to a nested message loop
// that answers requests until the client resumes. One consequence is honest
// and documented: a running program cannot be interrupted from outside, so
// `pause` only answers when the program is already stopped.

package main

import std.fs
import std.io
import std.path

// ---------------------------------------------------------------------------
// One stack frame the client can see
// ---------------------------------------------------------------------------

class DebugFrame {
    id: int
    name: string
    file: string
    line: int
    col: int
    frame: TreeFrame
    function: HirFunction

    fn init(id: int, name: string, function: HirFunction,
            frame: TreeFrame) {
        self.id = id
        self.name = name
        self.file = function.file
        self.line = function.line
        self.col = function.col
        self.frame = frame
        self.function = function
    }
}

// What a `variablesReference` stands for.
class DebugScopeRef {
    kind: string
    frame_id: int
    value: TreeValue

    fn init(kind: string, frame_id: int, value: TreeValue) {
        self.kind = kind
        self.frame_id = frame_id
        self.value = value
    }
}

// One variable, before it is rendered as JSON.
class DebugVariable {
    name: string
    value: string
    type_name: string
    reference: int
    count: int

    fn init(name: string, value: string, type_name: string) {
        self.name = name
        self.value = value
        self.type_name = type_name
        self.reference = 0
        self.count = 0
    }
}

// ---------------------------------------------------------------------------
// Values as a person reads them
// ---------------------------------------------------------------------------

fn dap_value_summary(value: TreeValue) -> string {
    if value.kind == "unit" { return "unit" }
    if value.kind == "bool" {
        return if value.bool_data { "true" } else { "false" }
    }
    if value.kind == "string" {
        return "\"{value.text}\""
    }
    if value.kind == "list" {
        return "[{value.items.len()} item(s)]"
    }
    if value.kind == "map" {
        return "\{{value.map_keys.len()} entry(s)\}"
    }
    if value.kind == "object" {
        return "{display_symbol(value.text)} \{...\}"
    }
    if value.kind == "enum" {
        if value.items.len() == 0 {
            return display_symbol(value.text)
        }
        return "{display_symbol(value.text)}(...)"
    }
    if value.kind == "closure" { return "fn(...)" }
    return tree_value_text(value)
}

fn dap_value_type(value: TreeValue) -> string {
    if value.kind == "object" || value.kind == "enum" {
        // The canonical symbol carries "::"; a reader wants the spelling
        // source uses.
        if value.text != "" { return display_symbol(value.text) }
    }
    if value.kind == "int" {
        if value.int_unsigned { return "u{value.int_bits}" }
        if value.int_bits == 64 { return "int" }
        return "i{value.int_bits}"
    }
    return value.kind
}

// True when a value has parts worth expanding.
fn dap_value_expandable(value: TreeValue) -> bool {
    if value.kind == "list" { return value.items.len() != 0 }
    if value.kind == "map" { return value.map_keys.len() != 0 }
    if value.kind == "object" { return true }
    if value.kind == "enum" { return value.items.len() != 0 }
    return false
}

fn dap_child_count(value: TreeValue) -> int {
    if value.kind == "list" { return value.items.len() }
    if value.kind == "map" { return value.map_keys.len() }
    if value.kind == "object" { return value.fields.keys().len() }
    if value.kind == "enum" { return value.items.len() }
    return 0
}

// ---------------------------------------------------------------------------
// The session
// ---------------------------------------------------------------------------

class DebugSession {
    sequence: int
    program: HirProgram
    interpreter: Option<TreeInterpreter>
    entry_file: string
    // normalized path -> the lines the client asked to break on
    breakpoints: Map<string, List<int>>
    // normalized path -> the lines that actually carry a statement
    executable: Map<string, List<int>>
    // binding id -> the name the source gave it
    names: Map<int, string>
    stop_on_entry: bool
    configured: bool
    running: bool
    terminated: bool
    disconnected: bool
    // "run" | "entry" | "over" | "in" | "out"
    mode: string
    step_depth: int
    stack: List<DebugFrame>
    next_frame_id: int
    references: Map<int, DebugScopeRef>
    next_reference: int
    previous_file: string
    previous_line: int
    exit_code: int

    fn init(program: HirProgram, entry_file: string) {
        self.sequence = 0
        self.program = program
        self.interpreter = none
        self.entry_file = entry_file
        self.breakpoints = {}
        self.executable = {}
        self.names = {}
        self.stop_on_entry = false
        self.configured = false
        self.running = false
        self.terminated = false
        self.disconnected = false
        self.mode = "run"
        self.step_depth = 0
        self.stack = []
        self.next_frame_id = 1
        self.references = {}
        self.next_reference = 1000
        self.previous_file = ""
        self.previous_line = -1
        self.exit_code = 0
        self.collect_lines()
    }

    // Where a breakpoint can land, and what every binding id is called. Both
    // come from the checked HIR, so they describe the program that will
    // actually run.
    fn collect_lines() {
        for function: HirFunction in self.program.functions {
            for parameter: HirParameter in function.parameters {
                if parameter.binding_id >= 0 {
                    self.names[parameter.binding_id] =
                        parameter.name
                }
            }
            if function.self_binding_id >= 0 {
                self.names[function.self_binding_id] = "self"
            }
            for statement: HirNode in function.body {
                self.collect_node(statement)
            }
        }
    }

    fn collect_node(node: HirNode) {
        if node.binding_id >= 0 && node.value != "" &&
           node.kind != "local" {
            self.names[node.binding_id] = node.value
        }
        if node.line > 0 && node.file != "" &&
           self.is_statement(node.kind) {
            let key: string = dap_normalize(node.file)
            if !self.executable.contains_key(key) {
                self.executable[key] = []
            }
            if !self.executable[key].contains(node.line) {
                self.executable[key].push(node.line)
            }
        }
        for child: HirNode in node.children {
            self.collect_node(child)
        }
    }

    // The node kinds the interpreter stops on. Keeping one list means a
    // breakpoint can only be verified onto a line execution really reaches.
    fn is_statement(kind: string) -> bool {
        return kind == "let" || kind == "var" ||
               kind == "expression" || kind == "assign" ||
               kind == "return" || kind == "if" ||
               kind == "for" || kind == "loop" ||
               kind == "match" || kind == "defer" ||
               kind == "break" || kind == "continue"
    }

    // -----------------------------------------------------------------
    // Wire
    // -----------------------------------------------------------------

    fn send(body: string) {
        lsp_write_message(body)
    }

    fn next_sequence() -> int {
        self.sequence += 1
        return self.sequence
    }

    fn event(kind: string, body: string) {
        var fields: List<string> = [
            lsp_member("seq", "{self.next_sequence()}"),
            lsp_member("type", lsp_quote("event")),
            lsp_member("event", lsp_quote(kind))]
        if body != "" {
            fields.push(lsp_member("body", body))
        }
        self.send(lsp_object(fields))
    }

    fn respond(request: BindgenJson, body: string) {
        var fields: List<string> = [
            lsp_member("seq", "{self.next_sequence()}"),
            lsp_member("type", lsp_quote("response")),
            lsp_member(
                "request_seq",
                "{lsp_json_number(request, "seq")}"),
            lsp_member("success", "true"),
            lsp_member(
                "command",
                lsp_quote(request.string("command")))]
        if body != "" {
            fields.push(lsp_member("body", body))
        }
        self.send(lsp_object(fields))
    }

    fn refuse(request: BindgenJson, message: string) {
        self.send(
            lsp_object([
                lsp_member("seq", "{self.next_sequence()}"),
                lsp_member("type", lsp_quote("response")),
                lsp_member(
                    "request_seq",
                    "{lsp_json_number(request, "seq")}"),
                lsp_member("success", "false"),
                lsp_member(
                    "command",
                    lsp_quote(request.string("command"))),
                lsp_member("message", lsp_quote(message))]))
    }

    // Program output never shares the protocol stream: it is forwarded as an
    // output event, which is what puts it in the client's debug console.
    fn program_output(text: string, category: string) {
        self.event(
            "output",
            lsp_object([
                lsp_member("category", lsp_quote(category)),
                lsp_member("output", lsp_quote(text))]))
    }

    // -----------------------------------------------------------------
    // Breakpoints
    // -----------------------------------------------------------------

    // The line a breakpoint really lands on: the requested line when it
    // carries a statement, otherwise the nearest one below it, otherwise the
    // nearest one above. -1 when the file has no executable line at all.
    fn resolve_line(file_path: string, wanted: int) -> int {
        for key: string in self.executable.keys() {
            if !dap_same_file(key, file_path) { continue }
            var best_below: int = -1
            var best_above: int = -1
            for line: int in self.executable[key] {
                if line == wanted { return line }
                if line > wanted {
                    if best_below < 0 || line < best_below {
                        best_below = line
                    }
                } else {
                    if line > best_above { best_above = line }
                }
            }
            if best_below >= 0 { return best_below }
            return best_above
        }
        return -1
    }

    fn breakpoint_hit(file_path: string, line: int) -> bool {
        for key: string in self.breakpoints.keys() {
            if !dap_same_file(key, file_path) { continue }
            if self.breakpoints[key].contains(line) { return true }
        }
        return false
    }

    // -----------------------------------------------------------------
    // Frames
    // -----------------------------------------------------------------

    fn push_frame(function: HirFunction, frame: TreeFrame) {
        let name: string =
            if function.owner == "" {
                function.name
            } else {
                "{symbol_name(function.owner)}.{function.name}"
            }
        let entry: DebugFrame =
            new DebugFrame(
                self.next_frame_id, name, function, frame)
        self.next_frame_id += 1
        self.stack.push(entry)
    }

    fn pop_frame() {
        if self.stack.len() == 0 { return }
        self.stack.pop()
    }

    fn top_frame() -> Option<DebugFrame> {
        if self.stack.len() == 0 { return none }
        return some(self.stack[self.stack.len() - 1])
    }

    fn frame_by_id(id: int) -> Option<DebugFrame> {
        for entry: DebugFrame in self.stack {
            if entry.id == id { return some(entry) }
        }
        return none
    }

    // -----------------------------------------------------------------
    // The stop check, called before every statement
    // -----------------------------------------------------------------

    fn at_statement(node: HirNode, frame: TreeFrame) {
        if self.terminated || self.disconnected { return }
        match self.top_frame() {
            some(entry) => {
                entry.file = node.file
                entry.line = node.line
                entry.col = node.col
                entry.frame = frame
            }
            none => { return }
        }
        let moved: bool =
            node.line != self.previous_line ||
            node.file != self.previous_file
        var reason: string = ""
        if self.mode == "entry" {
            reason = "entry"
        } else if moved &&
                  self.breakpoint_hit(node.file, node.line) {
            reason = "breakpoint"
        } else if self.mode == "in" && moved {
            reason = "step"
        } else if self.mode == "over" && moved &&
                  self.stack.len() <= self.step_depth {
            reason = "step"
        } else if self.mode == "out" &&
                  self.stack.len() < self.step_depth {
            reason = "step"
        }
        self.previous_file = node.file
        self.previous_line = node.line
        if reason == "" { return }
        self.mode = "run"
        self.stop(reason, "")
    }

    // A runtime panic stops with the frames still standing, so a person can
    // see what the program was doing when it failed.
    fn at_panic(message: string) {
        if self.terminated || self.disconnected { return }
        self.stop("exception", message)
    }

    // Announce the stop, then answer requests until the client resumes.
    fn stop(reason: string, text: string) {
        self.references = {}
        var fields: List<string> = [
            lsp_member("reason", lsp_quote(reason)),
            lsp_member("threadId", "1"),
            lsp_member("allThreadsStopped", "true")]
        if text != "" {
            fields.push(
                lsp_member("description", lsp_quote(text)))
            fields.push(lsp_member("text", lsp_quote(text)))
        }
        self.event("stopped", lsp_object(fields))
        self.running = false
        for !self.running && !self.disconnected &&
            !self.terminated {
            match lsp_read_message() {
                some(body) => {
                    let parser: BindgenJsonParser =
                        new BindgenJsonParser(body)
                    let message: BindgenJson = parser.value()
                    if parser.ok && message.kind == "object" {
                        self.handle(message)
                    }
                }
                none => {
                    self.disconnected = true
                    return
                }
            }
        }
    }

    // -----------------------------------------------------------------
    // Variables
    // -----------------------------------------------------------------

    fn reference_for(kind: string, frame_id: int,
                     value: TreeValue) -> int {
        let id: int = self.next_reference
        self.next_reference += 1
        self.references[id] =
            new DebugScopeRef(kind, frame_id, value)
        return id
    }

    // What a reference cell really holds: the interpreter stores a borrowed
    // binding as a reference into another frame.
    fn resolve_value(value: TreeValue) -> TreeValue {
        if value.kind != "reference" { return value }
        match value.reference_frame {
            some(target) => {
                match target.get(value.reference_binding) {
                    some(found) => { return found }
                    none => { return value }
                }
            }
            none => { return value }
        }
    }

    fn describe(name: string, raw: TreeValue) -> DebugVariable {
        let value: TreeValue = self.resolve_value(raw)
        let variable: DebugVariable =
            new DebugVariable(
                name, dap_value_summary(value),
                dap_value_type(value))
        if dap_value_expandable(value) {
            variable.reference =
                self.reference_for("value", 0, value)
            variable.count = dap_child_count(value)
        }
        return variable
    }

    // Everything in scope in a frame: `self`, the parameters, and every local
    // the interpreter has bound, walking out through the enclosing block
    // scopes and any captured frame. Two shadowed locals keep separate
    // binding ids, so both appear with their own value.
    fn frame_variables(entry: DebugFrame) -> List<DebugVariable> {
        var found: List<DebugVariable> = []
        var seen: Map<int, bool> = {}
        var current: Option<TreeFrame> = some(entry.frame)
        for current.is_some() {
            match current {
                some(frame) => {
                    var ids: List<int> = frame.values.keys()
                    ids.sort()
                    for binding: int in ids {
                        if seen.contains_key(binding) { continue }
                        seen[binding] = true
                        var name: string = "#{binding}"
                        match self.names.get(binding) {
                            some(known) => { name = known }
                            none => {}
                        }
                        found.push(
                            self.describe(
                                name, frame.values[binding]))
                    }
                    current = frame.parent
                }
                none => {}
            }
        }
        return move found
    }

    // One binding by name, looked up the same way the variables view finds
    // it: innermost frame first, then out through the enclosing scopes.
    fn frame_binding(entry: DebugFrame,
                     wanted: string) -> Option<TreeValue> {
        var current: Option<TreeFrame> = some(entry.frame)
        for true {
            match current {
                some(frame) => {
                    for binding: int in frame.values.keys() {
                        match self.names.get(binding) {
                            some(name) => {
                                if name == wanted {
                                    return some(
                                        self.resolve_value(
                                            frame.values[binding]))
                                }
                            }
                            none => {}
                        }
                    }
                    current = frame.parent
                }
                none => { return none }
            }
        }
        return none
    }

    fn children_of(value: TreeValue, start: int,
                   count: int) -> List<DebugVariable> {
        var found: List<DebugVariable> = []
        var total: int = dap_child_count(value)
        var from: int = if start < 0 { 0 } else { start }
        var limit: int =
            if count <= 0 { total } else { from + count }
        if limit > total { limit = total }
        if value.kind == "list" || value.kind == "enum" {
            for index: int in from..limit {
                found.push(
                    self.describe("{index}", value.items[index]))
            }
            return move found
        }
        if value.kind == "map" {
            for index: int in from..limit {
                let key: TreeValue = value.map_keys[index]
                let shown: string = tree_value_text(key)
                match value.map_values.get(
                          tree_value_key(key)) {
                    some(entry) => {
                        found.push(self.describe(shown, entry))
                    }
                    none => {}
                }
            }
            return move found
        }
        if value.kind == "object" {
            var names: List<string> = value.fields.keys()
            names.sort()
            for index: int in from..limit {
                let name: string = names[index]
                found.push(
                    self.describe(name, value.fields[name]))
            }
            return move found
        }
        return move found
    }

    fn render_variable(variable: DebugVariable) -> string {
        var fields: List<string> = [
            lsp_member("name", lsp_quote(variable.name)),
            lsp_member("value", lsp_quote(variable.value)),
            lsp_member("type", lsp_quote(variable.type_name)),
            lsp_member(
                "variablesReference", "{variable.reference}")]
        if variable.count > 0 {
            fields.push(
                lsp_member(
                    "indexedVariables", "{variable.count}"))
        }
        return lsp_object(fields)
    }

    // -----------------------------------------------------------------
    // Expression evaluation
    // -----------------------------------------------------------------

    // A variable path in the selected frame: a name, then any run of `.field`
    // and `[index]`. That covers what a person types into a watch window; a
    // path that names nothing answers with an error rather than a guess.
    fn evaluate_path(entry: DebugFrame,
                     source: string) -> Option<TreeValue> {
        let lexer: Lexer = new Lexer(source)
        let tokens: List<Token> = lexer.scan()
        if lexer.errors.len() != 0 { return none }
        if tokens.len() == 0 { return none }
        var at: int = 0
        if tokens[at].kind != "ident" &&
           tokens[at].kind != "self" {
            return none
        }
        let root: string = tokens[at].text
        at += 1
        var found: Option<TreeValue> =
            self.frame_binding(entry, root)
        var value: TreeValue = TreeValue.unit()
        match found {
            some(start) => { value = start }
            none => { return none }
        }
        for at < tokens.len() {
            let token: Token = tokens[at]
            if token.kind == "eof" ||
               token.kind == "newline" {
                break
            }
            if token.kind == "." {
                at += 1
                if at >= tokens.len() ||
                   tokens[at].kind != "ident" {
                    return none
                }
                let field: string = tokens[at].text
                at += 1
                if value.kind != "object" { return none }
                match value.fields.get(field) {
                    some(next) => {
                        value = self.resolve_value(next)
                    }
                    none => { return none }
                }
                continue
            }
            if token.kind == "[" {
                at += 1
                if at >= tokens.len() ||
                   tokens[at].kind != "int" {
                    return none
                }
                let index: int = tokens[at].text.to_int().or(-1)
                at += 1
                if at >= tokens.len() ||
                   tokens[at].kind != "]" {
                    return none
                }
                at += 1
                if value.kind != "list" { return none }
                if index < 0 || index >= value.items.len() {
                    return none
                }
                value = self.resolve_value(value.items[index])
                continue
            }
            return none
        }
        return some(value)
    }

    // -----------------------------------------------------------------
    // Requests
    // -----------------------------------------------------------------

    fn arguments_of(request: BindgenJson) -> BindgenJson {
        match request.get("arguments") {
            some(value) => { return value }
            none => { return new BindgenJson("object") }
        }
    }

    fn handle(message: BindgenJson) {
        if message.string("type") != "request" { return }
        let command: string = message.string("command")
        let arguments: BindgenJson = self.arguments_of(message)
        if command == "initialize" {
            self.respond(message, dap_capabilities())
            self.event("initialized", "")
            return
        }
        if command == "setBreakpoints" {
            self.set_breakpoints(message, arguments)
            return
        }
        if command == "setExceptionBreakpoints" {
            self.respond(
                message,
                lsp_object([
                    lsp_member("breakpoints", "[]")]))
            return
        }
        if command == "configurationDone" {
            self.configured = true
            self.respond(message, "")
            return
        }
        if command == "launch" {
            // The program starts after this reply, so the client sees the
            // acknowledgement before any stop.
            self.respond(message, "")
            self.stop_on_entry =
                self.flag(arguments, "stopOnEntry")
            self.running = true
            return
        }
        if command == "attach" {
            self.refuse(
                message,
                "the Beans debugger runs programs itself; there is nothing to attach to")
            return
        }
        if command == "threads" {
            self.respond(
                message,
                lsp_object([
                    lsp_member(
                        "threads",
                        lsp_array([
                            lsp_object([
                                lsp_member("id", "1"),
                                lsp_member(
                                    "name",
                                    lsp_quote("main"))])]))]))
            return
        }
        if command == "stackTrace" {
            self.stack_trace(message, arguments)
            return
        }
        if command == "scopes" {
            self.scopes(message, arguments)
            return
        }
        if command == "variables" {
            self.variables(message, arguments)
            return
        }
        if command == "evaluate" {
            self.evaluate(message, arguments)
            return
        }
        if command == "continue" {
            self.mode = "run"
            self.running = true
            self.respond(
                message,
                lsp_object([
                    lsp_member("allThreadsContinued", "true")]))
            self.event(
                "continued",
                lsp_object([
                    lsp_member("threadId", "1"),
                    lsp_member(
                        "allThreadsContinued", "true")]))
            return
        }
        if command == "next" || command == "stepIn" ||
           command == "stepOut" {
            self.mode =
                if command == "next" {
                    "over"
                } else if command == "stepIn" {
                    "in"
                } else {
                    "out"
                }
            self.step_depth = self.stack.len()
            self.running = true
            self.respond(message, "")
            return
        }
        if command == "pause" {
            // Honest: while the program runs the adapter is inside it and
            // reads nothing, so a pause can only arrive when it is already
            // stopped, where it means "stay stopped".
            if self.running {
                self.refuse(
                    message,
                    "a running Beans program cannot be interrupted; set a breakpoint instead")
                return
            }
            self.respond(message, "")
            self.event(
                "stopped",
                lsp_object([
                    lsp_member("reason", lsp_quote("pause")),
                    lsp_member("threadId", "1"),
                    lsp_member(
                        "allThreadsStopped", "true")]))
            return
        }
        if command == "disconnect" {
            self.disconnected = true
            self.respond(message, "")
            return
        }
        if command == "terminate" {
            self.terminated = true
            self.respond(message, "")
            return
        }
        self.refuse(
            message, "unsupported request '{command}'")
    }

    fn flag(arguments: BindgenJson, name: string) -> bool {
        match arguments.get(name) {
            some(value) => { return value.flag }
            none => { return false }
        }
    }

    fn set_breakpoints(request: BindgenJson,
                       arguments: BindgenJson) {
        var file_path: string = ""
        match arguments.get("source") {
            some(source) => {
                file_path = source.string("path")
            }
            none => {}
        }
        var wanted: List<int> = []
        var rendered: List<string> = []
        match arguments.get("breakpoints") {
            some(list) => {
                for item: BindgenJson in list.items {
                    wanted.push(lsp_json_number(item, "line"))
                }
            }
            none => {
                match arguments.get("lines") {
                    some(list) => {
                        for item: BindgenJson in list.items {
                            wanted.push(item.text.to_int().or(0))
                        }
                    }
                    none => {}
                }
            }
        }
        var settled: List<int> = []
        var index: int = 0
        for line: int in wanted {
            index += 1
            let landed: int = self.resolve_line(file_path, line)
            var fields: List<string> = [
                lsp_member("id", "{index}")]
            if landed < 0 {
                fields.push(lsp_member("verified", "false"))
                fields.push(
                    lsp_member(
                        "message",
                        lsp_quote(
                            "no Beans statement in this file to stop on")))
            } else {
                if !settled.contains(landed) {
                    settled.push(landed)
                }
                fields.push(lsp_member("verified", "true"))
                fields.push(lsp_member("line", "{landed}"))
                fields.push(
                    lsp_member(
                        "source",
                        lsp_object([
                            lsp_member(
                                "path",
                                lsp_quote(file_path))])))
            }
            rendered.push(lsp_object(fields))
        }
        self.breakpoints[dap_normalize(file_path)] = move settled
        self.respond(
            request,
            lsp_object([
                lsp_member(
                    "breakpoints", lsp_array(rendered))]))
    }

    fn stack_trace(request: BindgenJson,
                   arguments: BindgenJson) {
        var frames: List<string> = []
        var index: int = self.stack.len() - 1
        for index >= 0 {
            let entry: DebugFrame = self.stack[index]
            frames.push(
                lsp_object([
                    lsp_member("id", "{entry.id}"),
                    lsp_member("name", lsp_quote(entry.name)),
                    lsp_member(
                        "source",
                        lsp_object([
                            lsp_member(
                                "name",
                                lsp_quote(
                                    path.name(entry.file))),
                            lsp_member(
                                "path",
                                lsp_quote(entry.file))])),
                    lsp_member("line", "{entry.line}"),
                    lsp_member("column", "{entry.col}")]))
            index -= 1
        }
        self.respond(
            request,
            lsp_object([
                lsp_member("stackFrames", lsp_array(frames)),
                lsp_member(
                    "totalFrames", "{self.stack.len()}")]))
    }

    fn scopes(request: BindgenJson, arguments: BindgenJson) {
        let frame_id: int = lsp_json_number(arguments, "frameId")
        let reference: int =
            self.reference_for(
                "locals", frame_id, TreeValue.unit())
        var count: int = 0
        match self.frame_by_id(frame_id) {
            some(entry) => {
                count = self.frame_variables(entry).len()
            }
            none => {}
        }
        let scope: string =
            lsp_object([
                lsp_member("name", lsp_quote("Locals")),
                lsp_member(
                    "presentationHint", lsp_quote("locals")),
                lsp_member(
                    "variablesReference", "{reference}"),
                lsp_member("namedVariables", "{count}"),
                lsp_member("expensive", "false")])
        self.respond(
            request,
            lsp_object([
                lsp_member("scopes", lsp_array([scope]))]))
    }

    fn variables(request: BindgenJson,
                 arguments: BindgenJson) {
        let reference: int =
            lsp_json_number(arguments, "variablesReference")
        let start: int = lsp_json_number(arguments, "start")
        let count: int = lsp_json_number(arguments, "count")
        var rendered: List<string> = []
        match self.references.get(reference) {
            some(target) => {
                if target.kind == "locals" {
                    match self.frame_by_id(target.frame_id) {
                        some(entry) => {
                            var all: List<DebugVariable> =
                                self.frame_variables(entry)
                            var from: int =
                                if start < 0 { 0 } else { start }
                            var limit: int =
                                if count <= 0 {
                                    all.len()
                                } else {
                                    from + count
                                }
                            if limit > all.len() {
                                limit = all.len()
                            }
                            for index: int in from..limit {
                                rendered.push(
                                    self.render_variable(
                                        all[index]))
                            }
                        }
                        none => {}
                    }
                } else {
                    for variable: DebugVariable in
                        self.children_of(
                            target.value, start, count) {
                        rendered.push(
                            self.render_variable(variable))
                    }
                }
            }
            none => {}
        }
        self.respond(
            request,
            lsp_object([
                lsp_member(
                    "variables", lsp_array(rendered))]))
    }

    fn evaluate(request: BindgenJson,
                arguments: BindgenJson) {
        let source: string =
            arguments.string("expression").trim()
        let frame_id: int = lsp_json_number(arguments, "frameId")
        var entry: Option<DebugFrame> =
            self.frame_by_id(frame_id)
        match entry {
            none => { entry = self.top_frame() }
            some(found) => {}
        }
        match entry {
            some(found) => {
                match self.evaluate_path(found, source) {
                    some(value) => {
                        let variable: DebugVariable =
                            self.describe(source, value)
                        self.respond(
                            request,
                            lsp_object([
                                lsp_member(
                                    "result",
                                    lsp_quote(variable.value)),
                                lsp_member(
                                    "type",
                                    lsp_quote(
                                        variable.type_name)),
                                lsp_member(
                                    "variablesReference",
                                    "{variable.reference}")]))
                        return
                    }
                    none => {}
                }
            }
            none => {}
        }
        self.refuse(
            request,
            "cannot evaluate '{source}' here — the debugger reads variable paths such as `name`, `name.field` and `name[0]`")
    }
}

fn dap_capabilities() -> string {
    return lsp_object([
        lsp_member("supportsConfigurationDoneRequest", "true"),
        lsp_member("supportsEvaluateForHovers", "true"),
        lsp_member("supportsTerminateRequest", "true"),
        lsp_member("supportsDelayedStackTraceLoading", "false"),
        lsp_member("supportsSetVariable", "false"),
        lsp_member("supportsStepBack", "false"),
        lsp_member("supportsRestartRequest", "false"),
        lsp_member("supportsFunctionBreakpoints", "false"),
        lsp_member("supportsConditionalBreakpoints", "false"),
        lsp_member("supportsHitConditionalBreakpoints", "false"),
        lsp_member("exceptionBreakpointFilters", "[]")])
}

// A path the client and the compiler will both recognise. Clients send
// absolute paths; the compiler records whatever the command line gave it.
fn dap_normalize(file_path: string) -> string {
    if file_path == "" { return "" }
    return file_path
}

// Two paths name the same file when one ends with the other at a segment
// boundary. That is what lets a client's absolute path match a compiler
// diagnostic's relative one.
fn dap_same_file(left: string, right: string) -> bool {
    if left == "" || right == "" { return false }
    if left == right { return true }
    if left.len() > right.len() {
        return left.ends_with("/{right}")
    }
    return right.ends_with("/{left}")
}
