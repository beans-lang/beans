// `beansc debug-adapter` — the command an editor starts.
//
// It speaks DAP over stdio with Content-Length framing, the same framing the
// language server uses. The conversation runs in two halves: everything up to
// `launch` and `configurationDone` is answered here, and once the program
// starts the interpreter drives, handing control back at every stop.

package main

import std.fs
import std.io
import std.os
import std.path

class DebugLaunch {
    program: string
    cwd: string
    arguments: List<string>
    ok: bool

    fn init() {
        self.program = ""
        self.cwd = ""
        self.arguments = []
        self.ok = false
    }
}

fn dap_launch_arguments(arguments: BindgenJson) -> DebugLaunch {
    let launch: DebugLaunch = new DebugLaunch()
    launch.program = arguments.string("program")
    launch.cwd = arguments.string("cwd")
    match arguments.get("args") {
        some(list) => {
            for item: BindgenJson in list.items {
                launch.arguments.push(item.text)
            }
        }
        none => {}
    }
    launch.ok = launch.program != ""
    return launch
}

// Reply before the session exists: the client has to hear about a bad launch
// as a failed response, not as silence.
fn dap_reply_error(request: BindgenJson, sequence: int,
                   message: string) {
    lsp_write_message(
        lsp_object([
            lsp_member("seq", "{sequence}"),
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

fn dap_reply_ok(request: BindgenJson, sequence: int,
                body: string) {
    var fields: List<string> = [
        lsp_member("seq", "{sequence}"),
        lsp_member("type", lsp_quote("response")),
        lsp_member(
            "request_seq",
            "{lsp_json_number(request, "seq")}"),
        lsp_member("success", "true"),
        lsp_member(
            "command",
            lsp_quote(request.string("command")))]
    if body != "" { fields.push(lsp_member("body", body)) }
    lsp_write_message(lsp_object(fields))
}

fn dap_event(kind: string, sequence: int, body: string) {
    var fields: List<string> = [
        lsp_member("seq", "{sequence}"),
        lsp_member("type", lsp_quote("event")),
        lsp_member("event", lsp_quote(kind))]
    if body != "" { fields.push(lsp_member("body", body)) }
    lsp_write_message(lsp_object(fields))
}

// Build the program the debugger will run: the same pipeline `beansc run`
// uses, so what stops is what would execute.
class DebugBuild {
    ok: bool
    program: Option<HirProgram>
    message: string

    fn init() {
        self.ok = false
        self.program = none
        self.message = ""
    }
}

fn dap_build(entry: string) -> DebugBuild {
    let result: DebugBuild = new DebugBuild()
    let sources: SourceManager = new SourceManager()
    let loader: ModuleLoader =
        new ModuleLoader(sources, false, false, "use", "")
    if !loader.load(entry) {
        result.message = dap_first_error(loader.errors, entry)
        return result
    }
    let resolver: Resolver = new Resolver(loader)
    if !resolver.run() {
        result.message = dap_first_error(resolver.errors, entry)
        return result
    }
    var target: TargetDescription = supported_targets()[0]
    match host_target_description() {
        some(host) => { target = host }
        none => {}
    }
    let signatures: SignatureChecker =
        new SignatureChecker(resolver, target, "full")
    if !signatures.run() {
        result.message =
            dap_first_error(signatures.hir.errors, entry)
        return result
    }
    let expressions: ExpressionChecker =
        new ExpressionChecker(signatures)
    if !expressions.run() {
        result.message =
            dap_first_error(expressions.errors, entry)
        return result
    }
    var has_main: bool = false
    for function: HirFunction in signatures.hir.functions {
        if function.qualified == signatures.hir.entry_symbol {
            has_main = true
        }
    }
    if !has_main {
        result.message =
            "{entry}: this program has no 'fn main()' to debug"
        return result
    }
    result.ok = true
    result.program = some(signatures.hir)
    return result
}

fn dap_first_error(errors: List<Diagnostic>,
                   entry: string) -> string {
    for diagnostic: Diagnostic in errors {
        return render_diagnostic(diagnostic)
    }
    return "{entry}: the program did not compile"
}

fn run_debug_adapter() -> int {
    var sequence: int = 0
    var session: Option<DebugSession> = none
    var launch: DebugLaunch = new DebugLaunch()
    var initialized: bool = false
    var configured: bool = false
    var stop_on_entry: bool = false
    var launched: bool = false
    for {
        match lsp_read_message() {
            some(body) => {
                let parser: BindgenJsonParser =
                    new BindgenJsonParser(body)
                let message: BindgenJson = parser.value()
                if !parser.ok || message.kind != "object" {
                    continue
                }
                if message.string("type") != "request" {
                    continue
                }
                let command: string = message.string("command")
                var arguments: BindgenJson =
                    new BindgenJson("object")
                match message.get("arguments") {
                    some(value) => { arguments = value }
                    none => {}
                }
                if command == "initialize" {
                    sequence += 1
                    dap_reply_ok(
                        message, sequence, dap_capabilities())
                    sequence += 1
                    dap_event("initialized", sequence, "")
                    initialized = true
                    continue
                }
                if command == "launch" {
                    launch = dap_launch_arguments(arguments)
                    stop_on_entry =
                        dap_flag(arguments, "stopOnEntry")
                    if !launch.ok {
                        sequence += 1
                        dap_reply_error(
                            message, sequence,
                            "launch needs a 'program' path to a Beans file")
                        continue
                    }
                    let built: DebugBuild =
                        dap_build(launch.program)
                    if !built.ok {
                        sequence += 1
                        dap_reply_error(
                            message, sequence, built.message)
                        sequence += 1
                        dap_event(
                            "output", sequence,
                            lsp_object([
                                lsp_member(
                                    "category",
                                    lsp_quote("stderr")),
                                lsp_member(
                                    "output",
                                    lsp_quote(
                                        "{built.message}\n"))]))
                        sequence += 1
                        dap_event("terminated", sequence, "")
                        continue
                    }
                    match built.program {
                        some(program) => {
                            let live: DebugSession =
                                new DebugSession(
                                    program, launch.program)
                            live.sequence = sequence
                            session = some(live)
                        }
                        none => {}
                    }
                    sequence += 1
                    dap_reply_ok(message, sequence, "")
                    launched = true
                    continue
                }
                if command == "setBreakpoints" ||
                   command == "setExceptionBreakpoints" ||
                   command == "configurationDone" ||
                   command == "threads" ||
                   command == "disconnect" ||
                   command == "terminate" ||
                   command == "stackTrace" ||
                   command == "scopes" ||
                   command == "variables" ||
                   command == "evaluate" ||
                   command == "pause" ||
                   command == "attach" {
                    match session {
                        some(live) => {
                            live.sequence = sequence
                            live.handle(message)
                            sequence = live.sequence
                            if live.disconnected ||
                               live.terminated {
                                return 0
                            }
                            if command == "configurationDone" {
                                configured = true
                            }
                        }
                        none => {
                            // Before launch there is no program yet, but the
                            // client still needs an answer.
                            sequence += 1
                            if command == "setBreakpoints" {
                                dap_reply_ok(
                                    message, sequence,
                                    lsp_object([
                                        lsp_member(
                                            "breakpoints",
                                            "[]")]))
                            } else if command == "threads" {
                                dap_reply_ok(
                                    message, sequence,
                                    lsp_object([
                                        lsp_member(
                                            "threads", "[]")]))
                            } else if command == "disconnect" ||
                                      command == "terminate" {
                                dap_reply_ok(
                                    message, sequence, "")
                                return 0
                            } else if command ==
                                          "configurationDone" {
                                configured = true
                                dap_reply_ok(
                                    message, sequence, "")
                            } else if command == "attach" {
                                dap_reply_error(
                                    message, sequence,
                                    "the Beans debugger runs programs itself; there is nothing to attach to")
                            } else {
                                dap_reply_ok(
                                    message, sequence,
                                    lsp_object([]))
                            }
                        }
                    }
                    if launched && configured {
                        match session {
                            some(live) => {
                                let status: int =
                                    dap_execute(
                                        live, launch,
                                        stop_on_entry)
                                return status
                            }
                            none => {}
                        }
                    }
                    continue
                }
                match session {
                    some(live) => {
                        live.sequence = sequence
                        live.handle(message)
                        sequence = live.sequence
                    }
                    none => {
                        sequence += 1
                        dap_reply_error(
                            message, sequence,
                            "unsupported request '{command}' before launch")
                    }
                }
            }
            none => { return 0 }
        }
    }
    return 0
}

fn dap_flag(arguments: BindgenJson, name: string) -> bool {
    match arguments.get(name) {
        some(value) => { return value.flag }
        none => { return false }
    }
}

// Run the program under the session, then report how it ended.
fn dap_execute(session: DebugSession, launch: DebugLaunch,
               stop_on_entry: bool) -> int {
    var run_arguments: List<string> = [launch.program]
    for value: string in launch.arguments {
        run_arguments.push(value)
    }
    // `cwd` belongs to the process, and the client sets it when it spawns the
    // adapter — the same arrangement every DAP adapter uses. Saying so out
    // loud beats silently running somewhere else.
    if launch.cwd != "" {
        session.event(
            "output",
            lsp_object([
                lsp_member("category", lsp_quote("console")),
                lsp_member(
                    "output",
                    lsp_quote(
                        "working directory: {launch.cwd}\n"))]))
    }
    let interpreter: TreeInterpreter =
        new TreeInterpreter(
            session.program, move run_arguments)
    interpreter.debugger = some(session)
    session.interpreter = some(interpreter)
    session.mode = if stop_on_entry { "entry" } else { "run" }
    session.running = true
    let ok: bool = interpreter.run()
    if session.disconnected { return 0 }
    if !ok {
        session.exit_code = 3
        session.event(
            "output",
            lsp_object([
                lsp_member(
                    "category", lsp_quote("stderr")),
                lsp_member(
                    "output",
                    lsp_quote(
                        "{interpreter.panic_text}\n"))]))
    }
    session.event(
        "exited",
        lsp_object([
            lsp_member("exitCode", "{session.exit_code}")]))
    session.event("terminated", "")
    // Stay up until the client says goodbye, the way a debug adapter should:
    // it still wants to read the final stack or disconnect cleanly.
    for !session.disconnected && !session.terminated {
        match lsp_read_message() {
            some(body) => {
                let parser: BindgenJsonParser =
                    new BindgenJsonParser(body)
                let message: BindgenJson = parser.value()
                if parser.ok && message.kind == "object" {
                    session.handle(message)
                }
            }
            none => { return 0 }
        }
    }
    return 0
}
