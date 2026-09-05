package main

import std.fs
import std.io
import std.os
import std.path
import std.process
import std.random
import std.time

// This text is public surface. Focused CLI tests pin commands and options so a
// change here must be reflected in the documentation and behaviour together.
fn print_usage() {
    io.eprintln("usage: beansc <lex|parse|check|mir|run> <file.b>...")
    io.eprintln("       beansc build [options] <file.b> [-o out]")
    io.eprintln("       beansc bindgen <header.h>... -o <bindings.b> [options] [-- clang-options]")
    io.eprintln("       beansc pot init <module-name>")
    io.eprintln("       beansc pot add <dependency> [ref]")
    io.eprintln("       beansc pot add --system <pkg-config-name>")
    io.eprintln("       beansc pot remove <dependency>")
    io.eprintln("       beansc pot remove --system <pkg-config-name>")
    io.eprintln("       beansc pot update --system <pkg-config-name>")
    io.eprintln("       beansc pot <tidy|update [dependency]>")
    io.eprintln("       beansc upgrade")
    io.eprintln("       beansc doctor")
    io.eprintln("       beansc lsp-probe <file.b>:<line>:<col>")
    io.eprintln("       beansc lsp   (language server on stdio)")
    io.eprintln("       beansc --version")
    io.eprintln("")
    io.eprintln("build options:")
    io.eprintln("  (no flag)              -O0, for a fast edit-build-run loop")
    io.eprintln("  --release              -O3, NDEBUG")
    io.eprintln("  --debug                -O0, debug information, frame pointers")
    io.eprintln("  --lto                  link-time optimization")
    io.eprintln("  --target <triple>      {supported_target_names()}")
    io.eprintln("  --cpu <generic|native|name>")
    io.eprintln("  --features <+f,-f,...> enable or disable CPU features")
    io.eprintln("  --sysroot <path>       target sysroot for a cross link")
    io.eprintln("  --cc <path>            C driver to use (default clang)")
    io.eprintln("  --linker <name|path>   pass -fuse-ld=<value>; a full path works")
    io.eprintln("  --ar <path>            static archive tool (default ar)")
    io.eprintln("  --header <path>        write a C header for library exports")
    io.eprintln("  --emit <bin|obj|static|shared|ir>")
    io.eprintln("  --runtime <full|minimal|freestanding>")
    io.eprintln("                         how much runtime; anything a profile")
    io.eprintln("                         drops is refused at check time")
    io.eprintln("  --locked               require exact beans.lock entries")
    io.eprintln("  --offline              forbid dependency network access")
}

fn supported_target_names() -> string {
    var names: List<string> = []
    for target: TargetDescription in supported_targets() {
        names.push(target.triple)
    }
    return names.join(", ")
}

fn configured_target(written: string, cpu: string,
                     feature_lists: List<string>) ->
    Result<TargetDescription, string> {
    var selected: TargetDescription = supported_targets()[0]
    var found: bool = false
    let requested: Option<TargetDescription> =
        if written == "" {
            host_target_description()
        } else {
            find_target(written)
        }
    match requested {
        some(target) => {
            selected = target
            found = true
        }
        none => {}
    }
    if !found {
        let shown: string =
            if written == "" {
                host_target_name()
            } else {
                written
            }
        return err(
            "unknown target '{shown}'; supported targets are {supported_target_names()}")
    }
    if cpu == "native" &&
       selected.triple != host_target_name() {
        return err(
            "--cpu native needs a host build; target {selected.triple} is not the host ({host_target_name()})")
    }
    let cpu_error: string = selected.apply_cpu(cpu)
    if cpu_error != "" { return err(cpu_error) }
    for features: string in feature_lists {
        let feature_error: string =
            selected.apply_feature_list(features)
        if feature_error != "" { return err(feature_error) }
    }
    return ok(selected)
}

fn module_entry() -> string {
    if !File.exists("beans.pot") { return "" }
    if File.exists("main.b") { return "./main.b" }
    let names: List<string> = Dir.list(".").expect("list module")
    for name: string in names {
        if name.ends_with(".b") { return "./{name}" }
    }
    return ""
}

fn normalized_dependency(written: string) -> string {
    var value: string = written.trim()
    if value.starts_with("https://") {
        value = value.slice(8, value.len())
    } else if value.starts_with("http://") {
        value = value.slice(7, value.len())
    } else if value.starts_with("git@") {
        let remote: string = value.slice(4, value.len())
        match remote.find(":") {
            some(colon) => {
                value = "{remote.slice(0, colon)}/{remote.slice(colon + 1, remote.len())}"
            }
            none => { return "" }
        }
    }
    if value.ends_with("/") {
        value = value.slice(0, value.len() - 1)
    }
    if value.ends_with(".git") {
        value = value.slice(0, value.len() - 4)
    }
    if value.split("/").len() == 2 {
        value = "github.com/{value}"
    }
    if !safe_remote_path(value) { return "" }
    return value
}

fn safe_dependency_ref(value: string) -> bool {
    if value == "" || value.starts_with("-") { return false }
    let words: List<string> =
        manifest_words("require github.com/owner/repo {value}")
    return words.len() == 3 && words[2] == value
}

fn safe_module_name(value: string) -> bool {
    if value == "" || value.starts_with(".") ||
       value.ends_with(".") {
        return false
    }
    for segment: string in value.split(".") {
        if !legal_package_name(segment) { return false }
    }
    return true
}

fn safe_system_package(value: string) -> bool {
    if value == "" || value.starts_with("-") { return false }
    var index: int = 0
    for index < value.len() {
        let byte: int = value.byte_at(index)
        if !((byte >= 48 && byte <= 57) ||
             (byte >= 65 && byte <= 90) ||
             (byte >= 97 && byte <= 122) ||
             byte == 43 || byte == 45 || byte == 46 ||
             byte == 95) {
            return false
        }
        index += 1
    }
    return true
}

// pkg-config prints shell-style words even though beansc never invokes a
// shell. Decode only quoting and backslash escapes, then pass every word as a
// separate process argument.
fn pkg_config_words(text: string) -> Result<List<string>, string> {
    var words: List<string> = []
    var word: string = ""
    var started: bool = false
    var quote: int = 0
    var escaping: bool = false
    var index: int = 0
    for index < text.len() {
        let byte: int = text.byte_at(index)
        if escaping {
            if byte == 32 || byte == 9 || byte == 10 ||
               byte == 13 || byte == 92 || byte == 34 ||
               byte == 39 {
                word = "{word}{text.slice(index, index + 1)}"
            } else {
                word = "{word}\\{text.slice(index, index + 1)}"
            }
            started = true
            escaping = false
        } else if byte == 92 {
            escaping = true
            started = true
        } else if quote != 0 {
            if byte == quote {
                quote = 0
            } else {
                word = "{word}{text.slice(index, index + 1)}"
            }
        } else if byte == 34 || byte == 39 {
            quote = byte
            started = true
        } else if byte == 32 || byte == 9 ||
                  byte == 10 || byte == 13 {
            if started {
                words.push(word)
                word = ""
                started = false
            }
        } else {
            word = "{word}{text.slice(index, index + 1)}"
            started = true
        }
        index += 1
    }
    if escaping || quote != 0 {
        return err("pkg-config returned an unterminated quoted value")
    }
    if started { words.push(word) }
    return ok(move words)
}

// `; MIR <op> vN` above every emitted instruction is a reading aid for
// whoever is debugging the backend, and nothing downstream parses it. On a
// self-build it is a twelfth of the text clang has to lex, so it is off
// unless asked for. Set BEANS_IR_COMMENTS to anything but "" or "0".
fn ir_comments_requested() -> bool {
    match os.env("BEANS_IR_COMMENTS") {
        some(value) => {
            return value != "" && value != "0"
        }
        none => {}
    }
    return false
}

fn pkg_config_program() -> string {
    match os.env("PKG_CONFIG") {
        some(value) => {
            if value != "" { return value }
        }
        none => {}
    }
    return "pkg-config"
}

fn pkg_config_flags(package: string,
                    option: string) -> Result<List<string>, string> {
    let command: process.Command =
        new process.Command(pkg_config_program())
    command.arg(option)
    command.arg(package)
    match command.run() {
        ok(done) => {
            if !done.succeeded() {
                let detail: string = done.stderr_text().trim()
                return err(
                    if detail == "" {
                        "pkg-config could not find '{package}'"
                    } else {
                        "pkg-config could not find '{package}': {detail}"
                    })
            }
            return pkg_config_words(done.stdout_text())
        }
        err(error) => {
            return err(
                "cannot start {pkg_config_program()}: {error.msg}")
        }
    }
}

fn pot_quote(value: string) -> string {
    return "\"{value.replace("\\", "\\\\").replace("\"", "\\\"")}\""
}

fn system_marker(package: string, end: bool) -> string {
    return "# beansc:system {package} {if end { "end" } else { "begin" }}"
}

fn system_link_block(package: string) -> Result<string, string> {
    let search_flags: List<string> =
        pkg_config_flags(package, "--libs-only-L")?
    let library_flags: List<string> =
        pkg_config_flags(package, "--libs-only-l")?
    let other_flags: List<string> =
        pkg_config_flags(package, "--libs-only-other")?
    if other_flags.len() != 0 {
        return err(
            "pkg-config package '{package}' needs unsupported linker flags: {other_flags.join(" ")}")
    }

    var output: string = "{system_marker(package, false)}\n"
    var links: int = 0
    for flag: string in search_flags {
        if flag.starts_with("-L") && flag.len() > 2 {
            output = "{output}link all search {pot_quote(flag.slice(2, flag.len()))}\n"
            links += 1
        }
    }
    for flag: string in library_flags {
        if flag.starts_with("-l") && flag.len() > 2 {
            output = "{output}link all library {pot_quote(flag.slice(2, flag.len()))}\n"
            links += 1
        }
    }
    if links == 0 {
        return err(
            "pkg-config package '{package}' did not report a library")
    }
    return ok("{output}{system_marker(package, true)}\n")
}

fn edit_pot_system(package: string, remove: bool,
                   update_only: bool) -> int {
    if module_entry() == "" {
        io.eprintln("error: run this command in a beans.pot project with a root .b file")
        return 2
    }
    var replacement: string = ""
    if !remove {
        match system_link_block(package) {
            ok(value) => { replacement = value }
            err(message) => {
                io.eprintln("error: {message}")
                return 1
            }
        }
    }
    var original: string = ""
    match fs.read("beans.pot") {
        ok(text) => { original = text }
        err(error) => {
            io.eprintln("beans.pot: error: cannot read manifest: {error.msg}")
            return 1
        }
    }

    let begin: string = system_marker(package, false)
    let end: string = system_marker(package, true)
    var output: string = ""
    var inside: bool = false
    var found: int = 0
    for line: string in original.lines() {
        if !inside && line.trim() == begin {
            found += 1
            inside = true
            if !remove { output = "{output}{replacement}" }
        } else if inside && line.trim() == end {
            inside = false
        } else if !inside {
            output = "{output}{line}\n"
        }
    }
    if inside {
        io.eprintln(
            "beans.pot: error: system package '{package}' has no end marker")
        return 1
    }
    if found > 1 {
        io.eprintln(
            "beans.pot: error: system package '{package}' appears more than once")
        return 1
    }
    if remove && found == 0 {
        io.eprintln(
            "beans.pot: error: system package '{package}' is not present")
        return 1
    }
    if update_only && found == 0 {
        io.eprintln(
            "beans.pot: error: system package '{package}' is not present")
        return 1
    }
    if !remove && found == 0 {
        output = original
        if output != "" && !output.ends_with("\n") {
            output = "{output}\n"
        }
        output = "{output}{replacement}"
    }

    let changed: bool = output != original
    if changed && !write_pot_manifest(output) { return 1 }
    if remove {
        io.println("removed system {package}")
    } else if found == 0 {
        io.println("added system {package}")
    } else if changed {
        io.println("updated system {package}")
    } else {
        io.println("kept system {package}")
    }
    return 0
}

fn write_pot_manifest(contents: string) -> bool {
    let manifest: string = "beans.pot"
    var nonce: int = 0
    match random.u64() {
        ok(value) => { nonce = value }
        err(error) => {
            io.eprintln(
                "beans.pot: error: cannot create a secure temporary name: {error.msg}")
            return false
        }
    }
    let temporary: string =
        "{manifest}.tmp-{time.monotonic_millis()}-{nonce}"
    match fs.write(temporary, contents) {
        ok(_) => {}
        err(error) => {
            File.remove(temporary)
            io.eprintln("beans.pot: error: cannot write manifest: {error.msg}")
            return false
        }
    }
    match File.rename(temporary, manifest) {
        ok(_) => { return true }
        err(error) => {
            File.remove(temporary)
            io.eprintln("beans.pot: error: cannot replace manifest: {error.msg}")
            return false
        }
    }
}

fn init_pot(module_name: string) -> int {
    if File.exists("beans.pot") {
        io.eprintln("error: beans.pot already exists")
        return 1
    }
    if !write_pot_manifest("module {module_name}\n") { return 1 }
    io.println("created beans.pot for module {module_name}")
    return 0
}

fn run_pot_lock(lock_mode: string, update_module: string,
                announce: bool) -> int {
    let entry: string = module_entry()
    if entry == "" {
        io.eprintln("error: run this command in a beans.pot project with a root .b file")
        return 2
    }
    let sources: SourceManager = new SourceManager()
    let loader: ModuleLoader =
        new ModuleLoader(sources, false, false,
                         lock_mode, update_module)
    let loaded: bool = loader.load(entry)
    if loaded && announce { io.println("wrote beans.lock") }
    for diagnostic: Diagnostic in loader.errors {
        io.eprintln(render_diagnostic(diagnostic))
    }
    return if loaded { 0 } else { 1 }
}

fn edit_pot_dependency(dependency: string, requested: string,
                       remove: bool) -> int {
    if module_entry() == "" {
        io.eprintln("error: run this command in a beans.pot project with a root .b file")
        return 2
    }
    var original: string = ""
    match fs.read("beans.pot") {
        ok(text) => { original = text }
        err(error) => {
            io.eprintln("beans.pot: error: cannot read manifest: {error.msg}")
            return 1
        }
    }

    var output: string = ""
    var found: int = 0
    var previous_ref: string = ""
    var line_number: int = 0
    for line: string in original.lines() {
        line_number += 1
        let words: List<string> = manifest_words(line)
        if words.len() == 1 &&
           words[0] == "$manifest-error:unterminated-quote$" {
            io.eprintln(
                "beans.pot:{line_number}:1: error: unterminated quoted string")
            return 1
        }
        let matches: bool =
            words.len() == 3 && words[0] == "require" &&
            words[1] == dependency
        if matches {
            found += 1
            previous_ref = words[2]
            if remove { continue }
            if previous_ref == requested {
                output = "{output}{line}\n"
            } else {
                var replaced: bool = false
                match line.find(dependency) {
                    some(dependency_at) => {
                        let after_dependency: int =
                            dependency_at + dependency.len()
                        let tail: string =
                            line.slice(after_dependency, line.len())
                        match tail.find(previous_ref) {
                            some(ref_at) => {
                                let start: int =
                                    after_dependency + ref_at
                                output =
                                    "{output}{line.slice(0, start)}{requested}{line.slice(start + previous_ref.len(), line.len())}\n"
                                replaced = true
                            }
                            none => {}
                        }
                    }
                    none => {}
                }
                if !replaced {
                    output =
                        "{output}require {dependency} {requested}\n"
                }
            }
        } else {
            output = "{output}{line}\n"
        }
    }
    if found > 1 {
        io.eprintln(
            "beans.pot: error: dependency '{dependency}' appears more than once")
        return 1
    }
    if remove && found == 0 {
        io.eprintln(
            "beans.pot: error: dependency '{dependency}' is not required")
        return 1
    }
    if !remove && found == 0 {
        output = original
        if output != "" && !output.ends_with("\n") {
            output = "{output}\n"
        }
        output = "{output}require {dependency} {requested}\n"
    }

    let changed: bool = output != original
    if changed && !write_pot_manifest(output) { return 1 }
    let status: int =
        run_pot_lock(if remove { "tidy" } else { "update" },
                     if remove { "" } else { dependency }, false)
    if status != 0 {
        if changed && !write_pot_manifest(original) {
            io.eprintln(
                "beans.pot: error: could not restore the manifest after the command failed")
        }
        return status
    }

    if remove {
        io.println("removed {dependency}")
    } else if found == 0 {
        io.println("added {dependency} {requested}")
    } else if previous_ref != requested {
        io.println("updated {dependency} {requested}")
    } else {
        io.println("kept {dependency} {requested}")
    }
    io.println("wrote beans.lock")
    return 0
}

fn module_artifact_name(name: string, source: string) -> string {
    if name == "" { return path.stem(source) }
    var result: string = name
    for part: string in name.split("/") {
        if part != "" { result = part }
    }
    var dotted: string = result
    for part: string in result.split(".") {
        if part != "" { dotted = part }
    }
    return dotted
}

fn run_upgrade() -> int {
    var root: string = ""
    match os.env("BEANS_HOME") {
        some(value) => { root = value }
        none => {}
    }
    if root == "" {
        io.eprintln(
            "error: beansc upgrade needs an installed Beans release")
        io.eprintln(
            "reinstall from https://github.com/beans-lang/beans#install")
        return 1
    }

    var windows: bool = false
    match host_target_description() {
        some(host) => { windows = host.os == "windows" }
        none => {}
    }
    let helper_name: string =
        if windows { "beans-install.ps1" } else { "beans-install.sh" }
    let helper: string =
        path.join(path.join(root, "libexec"), helper_name)
    if !File.exists(helper) {
        io.eprintln(
            "error: this Beans installation has no upgrade helper")
        io.eprintln(
            "reinstall from https://github.com/beans-lang/beans#install")
        return 1
    }
    if windows {
        io.eprintln(
            "error: on Windows, run 'beansc upgrade' through the installed beansc.cmd launcher")
        return 1
    }

    let command: process.Command = new process.Command("sh")
    command.arg(helper)
    command.arg("--prefix")
    command.arg(root)
    command.arg("--no-modify-path")
    match command.run() {
        ok(done) => {
            let output: string = done.stdout_text()
            let errors: string = done.stderr_text()
            if output != "" { io.print(output) }
            if errors != "" { io.eprint(errors) }
            return done.status
        }
        err(error) => {
            io.eprintln(
                "error: cannot start the Beans upgrade helper: {error.msg}")
            return 1
        }
    }
}

fn cli_number_field(value: int, width: int,
                    left: bool) -> string {
    let text: string = "{value}"
    if text.len() >= width { return text }
    let padding: string =
        " ".repeat(width - text.len())
    return if left {
        "{text}{padding}"
    } else {
        "{padding}{text}"
    }
}

fn cli_token_line(token: Token) -> string {
    let position: string =
        "{cli_number_field(token.line, 4, false)}:{cli_number_field(token.col, 3, true)} "
    if token.kind == "newline" ||
       token.kind == "eof" {
        return "{position}{token.kind}"
    }
    return "{position}{token.kind}{ " ".repeat(if token.kind.len() < 10 { 10 - token.kind.len() } else { 0 }) } {token.text}"
}

fn main() {
    let args: List<string> = os.args()
    if args.len() == 0 {
        print_usage()
        os.exit(2)
    }
    if args.len() == 1 &&
       (args[0] == "--version" ||
        args[0] == "version") {
        io.println(compiler_banner())
        return
    }

    let command: string = args[0]
    if command == "doctor" {
        if args.len() != 1 {
            io.eprintln("usage: beansc doctor")
            os.exit(2)
        }
        let status: int = run_doctor()
        if status != 0 { os.exit(status) }
        return
    }
    if command == "upgrade" {
        if args.len() != 1 {
            io.eprintln("usage: beansc upgrade")
            os.exit(2)
        }
        let status: int = run_upgrade()
        if status != 0 { os.exit(status) }
        return
    }
    if command == "lsp" {
        let status: int = run_self_lsp(args)
        if status != 0 { os.exit(status) }
        return
    }
    if command == "lsp-probe" {
        if args.len() != 2 {
            print_usage()
            os.exit(2)
        }
        let status: int =
            run_self_lsp_probe(args[1])
        if status != 0 { os.exit(status) }
        return
    }
    if command == "debug-adapter" {
        if args.len() != 1 {
            io.eprintln("usage: beansc debug-adapter")
            os.exit(2)
        }
        let status: int = run_debug_adapter()
        if status != 0 { os.exit(status) }
        return
    }
    if command == "sem-probe" {
        if args.len() != 3 {
            io.eprintln(
                "usage: beansc sem-probe <mode> <file.b>:<line>:<col>")
            os.exit(2)
        }
        let status: int =
            run_semantic_probe(args[1], args[2])
        if status != 0 { os.exit(status) }
        return
    }
    if command == "bindgen" {
        let status: int = run_self_bindgen(args)
        if status != 0 { os.exit(status) }
        return
    }
    if command == "target" {
        if args.len() != 2 {
            print_usage()
            os.exit(2)
        }
        match find_target(args[1]) {
            some(target) => { io.println(render_target(target)) }
            none => {
                io.println(
                    "error: unknown target '{args[1]}'; supported targets are {supported_target_names()}")
                os.exit(2)
            }
        }
        return
    }

    if command == "mod" {
        io.eprintln(
            "error: 'mod' is not a Beans command; use 'beansc pot init', 'beansc pot add', 'beansc pot tidy', 'beansc pot remove', or 'beansc pot update'")
        os.exit(2)
    }

    if command == "pot" {
        var status: int = 2
        if args.len() == 3 && args[1] == "init" {
            if !safe_module_name(args[2]) {
                io.eprintln(
                    "error: invalid module name '{args[2]}'; expected lowercase dot-separated names")
            } else {
                status = init_pot(args[2])
            }
        } else if args.len() == 4 && args[1] == "add" &&
           args[2] == "--system" {
            if !safe_system_package(args[3]) {
                io.eprintln("error: invalid pkg-config package name '{args[3]}'")
            } else {
                status = edit_pot_system(args[3], false, false)
            }
        } else if args.len() == 4 && args[1] == "remove" &&
                  args[2] == "--system" {
            if !safe_system_package(args[3]) {
                io.eprintln("error: invalid pkg-config package name '{args[3]}'")
            } else {
                status = edit_pot_system(args[3], true, false)
            }
        } else if args.len() == 4 && args[1] == "update" &&
                  args[2] == "--system" {
            if !safe_system_package(args[3]) {
                io.eprintln("error: invalid pkg-config package name '{args[3]}'")
            } else {
                status = edit_pot_system(args[3], false, true)
            }
        } else if (args.len() == 3 || args.len() == 4) &&
           args[1] == "add" {
            let dependency: string = normalized_dependency(args[2])
            let requested: string =
                if args.len() == 4 { args[3] } else { "HEAD" }
            if dependency == "" {
                io.eprintln(
                    "error: dependency must be owner/repo, host/owner/repo, or a Git URL")
            } else if !safe_dependency_ref(requested) {
                io.eprintln("error: invalid dependency ref '{requested}'")
            } else {
                status = edit_pot_dependency(
                    dependency, requested, false)
            }
        } else if args.len() == 3 && args[1] == "remove" {
            let dependency: string = normalized_dependency(args[2])
            if dependency == "" {
                io.eprintln(
                    "error: dependency must be owner/repo, host/owner/repo, or a Git URL")
            } else {
                status = edit_pot_dependency(dependency, "", true)
            }
        } else if args.len() == 2 && args[1] == "tidy" {
            status = run_pot_lock("tidy", "", true)
        } else if (args.len() == 2 || args.len() == 3) &&
                  args[1] == "update" {
            var dependency: string = ""
            if args.len() == 3 {
                dependency = normalized_dependency(args[2])
                if dependency == "" {
                    io.eprintln(
                        "error: dependency must be owner/repo, host/owner/repo, or a Git URL")
                    os.exit(2)
                }
            }
            status = run_pot_lock("update", dependency, true)
        } else {
            io.eprintln("usage: beansc pot init <module-name>")
            io.eprintln("       beansc pot add <dependency> [ref]")
            io.eprintln("       beansc pot add --system <pkg-config-name>")
            io.eprintln("       beansc pot tidy")
            io.eprintln("       beansc pot remove <dependency>")
            io.eprintln("       beansc pot remove --system <pkg-config-name>")
            io.eprintln("       beansc pot update [dependency]")
            io.eprintln("       beansc pot update --system <pkg-config-name>")
        }
        if status != 0 { os.exit(status) }
        return
    }

    if command != "lex" && command != "parse" &&
       command != "ast" && command != "load" &&
       command != "resolve" && command != "hir" &&
       command != "check" && command != "layout" &&
       command != "mir" && command != "llvm" &&
       command != "build" && command != "run" {
        if args.len() < 2 {
            print_usage()
        } else {
            io.eprintln("unknown command: {command}")
        }
        os.exit(2)
    }

    var file_path: string = ""
    var file_paths: List<string> = []
    var locked: bool = false
    var offline: bool = false
    var target_name: string = ""
    var cpu_name: string = "generic"
    var feature_lists: List<string> = []
    var runtime_profile: string = "full"
    var runtime_explicit: bool = false
    var release: bool = false
    var debug_build: bool = false
    var lto: bool = false
    var sysroot: string = ""
    var compiler_path: string = ""
    var linker: string = ""
    var output_path: string = ""
    var emit_kind: string = "bin"
    var emit_explicit: bool = false
    var ar_path: string = ""
    var header_path: string = ""
    var run_arguments: List<string> = []
    var passthrough: bool = false
    var index: int = 1
    for index < args.len() {
        if passthrough {
            run_arguments.push(args[index])
        } else if args[index] == "--" {
            if command != "run" || file_path == "" {
                print_usage()
                os.exit(2)
            }
            passthrough = true
        } else if args[index] == "--release" {
            release = true
        } else if args[index] == "--debug" {
            debug_build = true
        } else if args[index] == "--lto" {
            lto = true
        } else if args[index] == "--locked" {
            locked = true
        } else if args[index] == "--offline" {
            offline = true
        } else if args[index] == "--target" {
            index += 1
            if index >= args.len() {
                print_usage()
                os.exit(2)
            }
            target_name = args[index]
            if target_name == "" {
                io.eprintln("error: --target needs a value")
                os.exit(2)
            }
        } else if args[index] == "--cpu" {
            index += 1
            if index >= args.len() {
                print_usage()
                os.exit(2)
            }
            cpu_name = args[index]
            if cpu_name == "" {
                io.eprintln("error: --cpu needs a value")
                os.exit(2)
            }
        } else if args[index] == "--features" {
            index += 1
            if index >= args.len() {
                print_usage()
                os.exit(2)
            }
            if args[index] == "" {
                io.eprintln(
                    "error: --features needs a value")
                os.exit(2)
            }
            feature_lists.push(args[index])
        } else if args[index] == "--sysroot" {
            index += 1
            if index >= args.len() {
                print_usage()
                os.exit(2)
            }
            sysroot = args[index]
            if sysroot == "" {
                io.eprintln("error: --sysroot needs a value")
                os.exit(2)
            }
        } else if args[index] == "--cc" {
            index += 1
            if index >= args.len() {
                print_usage()
                os.exit(2)
            }
            compiler_path = args[index]
            if compiler_path == "" {
                io.eprintln("error: --cc needs a value")
                os.exit(2)
            }
        } else if args[index] == "--linker" {
            index += 1
            if index >= args.len() {
                print_usage()
                os.exit(2)
            }
            linker = args[index]
            if linker == "" {
                io.eprintln("error: --linker needs a value")
                os.exit(2)
            }
        } else if args[index] == "--runtime" {
            index += 1
            if index >= args.len() {
                print_usage()
                os.exit(2)
            }
            runtime_profile = args[index]
            runtime_explicit = true
        } else if args[index] == "-o" {
            index += 1
            if index >= args.len() {
                print_usage()
                os.exit(2)
            }
            output_path = args[index]
        } else if args[index] == "--emit" {
            index += 1
            if index >= args.len() {
                print_usage()
                os.exit(2)
            }
            emit_kind = args[index]
            emit_explicit = true
        } else if args[index] == "--ar" {
            index += 1
            if index >= args.len() {
                print_usage()
                os.exit(2)
            }
            ar_path = args[index]
        } else if args[index] == "--header" {
            index += 1
            if index >= args.len() {
                print_usage()
                os.exit(2)
            }
            header_path = args[index]
        } else if args[index].starts_with("-") {
            if command == "check" {
                io.eprintln(
                    "error: unknown check option: {args[index]} (check takes --target, --cpu, --features and --runtime)")
            } else {
                io.eprintln(
                    "error: unknown {command} option: {args[index]}")
            }
            os.exit(2)
        } else if command == "lex" ||
                  command == "parse" ||
                  command == "ast" {
            file_paths.push(args[index])
            if file_path == "" { file_path = args[index] }
        } else if file_path == "" {
            file_path = args[index]
        } else {
            if command == "build" {
                io.eprintln(
                    "error: build accepts one entry file")
            } else {
                print_usage()
            }
            os.exit(2)
        }
        index += 1
    }
    if file_path == "" ||
        (command != "lex" && command != "parse" &&
        command != "ast" &&
        command != "load" && command != "resolve" &&
        command != "hir" && command != "check" &&
        command != "layout" && command != "mir" &&
        command != "llvm" && command != "build" &&
        command != "run") ||
       ((command != "load" && command != "resolve" &&
         command != "hir" && command != "check" &&
         command != "layout" && command != "mir" &&
         command != "llvm" && command != "build" &&
         command != "run") &&
        (locked || offline)) {
        print_usage()
        os.exit(2)
    }
    if output_path != "" && command != "build" {
        print_usage()
        os.exit(2)
    }
    if header_path != "" && command != "build" {
        print_usage()
        os.exit(2)
    }
    if emit_kind != "bin" && emit_kind != "obj" &&
       emit_kind != "static" && emit_kind != "shared" &&
       emit_kind != "ir" {
        io.eprintln(
            "error: --emit must be bin, obj, static, shared or ir")
        os.exit(2)
    }
    if (emit_kind != "bin" && emit_kind != "obj" &&
        emit_kind != "static" && emit_kind != "shared" &&
        emit_kind != "ir") ||
       ((emit_kind != "bin" || ar_path != "") &&
        command != "build") {
        print_usage()
        os.exit(2)
    }
    if (target_name != "" || cpu_name != "generic" ||
        feature_lists.len() != 0 ||
        runtime_explicit) &&
       command != "check" && command != "layout" &&
       command != "mir" && command != "llvm" &&
       command != "build" {
        print_usage()
        os.exit(2)
    }
    if (release || lto || sysroot != "" ||
        compiler_path != "" || linker != "") &&
       command != "build" {
        print_usage()
        os.exit(2)
    }
    if sysroot != "" && !Dir.exists(sysroot) {
        io.eprintln(
            "error: --sysroot {sysroot} is not a directory")
        os.exit(2)
    }
    if compiler_path.contains("/") &&
       !File.exists(compiler_path) {
        io.eprintln(
            "error: --cc {compiler_path} does not exist")
        os.exit(2)
    }
    if linker.contains("/") && !File.exists(linker) {
        io.eprintln(
            "error: --linker {linker} does not exist")
        os.exit(2)
    }

    let sources: SourceManager = new SourceManager()
    let public_diagnostics: bool =
        command == "check" || command == "mir" ||
        command == "run" || command == "build"
    if release && debug_build {
        io.eprintln(
            "error: --release and --debug ask for opposite builds; pick one")
        os.exit(2)
    }
    if command == "load" || command == "resolve" || command == "hir" ||
       command == "check" || command == "layout" ||
       command == "mir" || command == "llvm" ||
       command == "build" ||
       command == "run" {
        let loader: ModuleLoader =
            new ModuleLoader(sources, locked, offline, "use", "")
        let loaded: bool = loader.load(file_path)
        if command == "load" { io.println(render_module_graph(loader)) }
        for diagnostic: Diagnostic in loader.errors {
            if public_diagnostics {
                io.eprintln(render_diagnostic(diagnostic))
            } else {
                io.println(render_diagnostic(diagnostic))
            }
        }
        if !loaded && command == "check" {
            io.eprintln(
                "{file_path}: stopped before type checking")
        }
        if !loaded { os.exit(1) }
        if command == "build" && loader.kind == "library" &&
           !emit_explicit {
            emit_kind = "static"
        }
        if command == "build" && loader.kind == "library" &&
           emit_kind == "bin" {
            io.eprintln(
                "{file_path}: error: a library cannot emit a binary; use --emit static, shared, obj, or ir")
            os.exit(1)
        }
        if command == "build" && header_path != "" &&
           emit_kind != "static" &&
           emit_kind != "shared" {
            io.eprintln(
                "{file_path}: error: --header is only valid with a static or shared library build")
            os.exit(1)
        }
        if command == "run" && loader.kind == "library" {
            io.eprintln(
                "{file_path}: error: a library cannot run — run an application, example, or test that imports it")
            os.exit(1)
        }
        if command == "resolve" || command == "hir" ||
           command == "check" || command == "layout" ||
           command == "mir" || command == "llvm" ||
           command == "build" ||
           command == "run" {
            let resolver: Resolver = new Resolver(loader)
            let resolved: bool = resolver.run()
            if command == "resolve" {
                io.println(render_resolution(resolver))
            }
            for diagnostic: Diagnostic in resolver.errors {
                if public_diagnostics {
                    io.eprintln(render_diagnostic(diagnostic))
                } else {
                    io.println(render_diagnostic(diagnostic))
                }
            }
            if !resolved && command == "resolve" { os.exit(1) }
            if command == "hir" || command == "check" ||
               command == "layout" || command == "mir" ||
               command == "llvm" || command == "build" ||
               command == "run" {
                var selected: TargetDescription =
                    supported_targets()[0]
                match configured_target(
                    target_name, cpu_name, feature_lists) {
                    ok(target) => { selected = target }
                    err(message) => {
                        io.eprintln("error: {message}")
                        os.exit(2)
                    }
                }
                if selected.os == "wasi" &&
                   !runtime_explicit {
                    runtime_profile = "minimal"
                }
                // Windows compiles the full runtime profile: the filesystem
                // tier has real Win32 branches, and the still-POSIX
                // subsystems are refused per-capability with their names.
                if selected.os == "none" &&
                   runtime_profile != "freestanding" {
                    io.eprintln(
                        "error: {selected.triple} has no operating system, so it needs --runtime freestanding, not {runtime_profile}")
                    os.exit(2)
                }
                if runtime_profile != "full" &&
                   runtime_profile != "minimal" &&
                   runtime_profile != "freestanding" {
                    io.eprintln(
                        "error: unknown --runtime '{runtime_profile}'; the profiles are full, minimal, freestanding")
                    os.exit(2)
                }
                let checker: SignatureChecker =
                    new SignatureChecker(
                        resolver, selected, runtime_profile)
                let checked: bool = checker.run()
                if command == "hir" {
                    io.println(render_hir(checker.hir))
                }
                for diagnostic: Diagnostic in checker.hir.errors {
                    if public_diagnostics {
                        io.eprintln(render_diagnostic(diagnostic))
                    } else {
                        io.println(render_diagnostic(diagnostic))
                    }
                }
                if (!resolved || !checked) &&
                   command == "hir" { os.exit(1) }
                var root_main: Option<HirFunction> = none
                for function: HirFunction in checker.hir.functions {
                    if function.qualified == checker.hir.entry_symbol {
                        root_main = some(function)
                    }
                }
                if loader.kind == "library" {
                    match root_main {
                        some(function) => {
                            io.eprintln(
                                "{function.file}:{function.line}:{function.col}: error: a library cannot declare 'main'; put runnable examples in an application package")
                            os.exit(1)
                        }
                        none => {}
                    }
                }
                if command == "run" ||
                   (command == "build" && emit_kind == "bin") {
                    match root_main {
                        some(function) => {
                            if function.parameters.len() != 0 ||
                               function.generics.len() != 0 ||
                               canonical_hir_name(
                                   function.result.name) != "unit" {
                                io.eprintln(
                                    "{function.file}:{function.line}:{function.col}: error: main must be 'fn main()' with no parameters, type parameters, or result")
                                os.exit(1)
                            }
                        }
                        none => {
                            io.eprintln(
                                "{file_path}: error: an application needs 'fn main()' in its module root; use 'kind library' or --emit static/shared for a library")
                            os.exit(1)
                        }
                    }
                }
                if command == "check" || command == "mir" ||
                   command == "llvm" || command == "build" ||
                   command == "run" {
                    let layouts: LayoutEngine =
                        new LayoutEngine(checker.hir, selected)
                    let layouts_ok: bool =
                        layouts.validate_for_check()
                    for diagnostic: Diagnostic in layouts.errors {
                        if public_diagnostics {
                            io.eprintln(render_diagnostic(diagnostic))
                        } else {
                            io.println(render_diagnostic(diagnostic))
                        }
                    }
                    let expressions: ExpressionChecker =
                        checker.expression_checker()
                    let expressions_ok: bool = expressions.run()
                    for diagnostic: Diagnostic in expressions.errors {
                        if public_diagnostics {
                            io.eprintln(render_diagnostic(diagnostic))
                        } else {
                            io.println(render_diagnostic(diagnostic))
                        }
                    }
                    if !resolved || !checked || !layouts_ok ||
                       !expressions_ok {
                        if command == "check" {
                            let count: int =
                                resolver.errors.len() +
                                checker.hir.errors.len() +
                                layouts.errors.len() +
                                expressions.errors.len()
                            io.println(
                                "{file_path}: {count} error(s)")
                        }
                        os.exit(1)
                    }
                    if command == "build" &&
                       header_path != "" {
                        match render_c_header(
                            checker.hir,
                            if loader.root != "" {
                                loader.module_name
                            } else {
                                path.stem(file_path)
                            }) {
                            ok(header) => {
                                match fs.write(
                                    header_path, header) {
                                    ok(_) => {
                                        io.println(
                                            "wrote {header_path}")
                                    }
                                    err(error) => {
                                        io.eprintln(
                                            "error: cannot write C header {header_path}: {error.msg}")
                                        os.exit(1)
                                    }
                                }
                            }
                            err(message) => {
                                io.eprintln(
                                    "{file_path}: error: {message}")
                                os.exit(1)
                            }
                        }
                    }
                    if command == "check" {
                        io.println("{file_path}: ok")
                    } else if command == "mir" ||
                              command == "llvm" ||
                              command == "build" {
                        let lowerer: MirLowerer =
                            new MirLowerer(checker.hir)
                        let mir: MirProgram = lowerer.run()
                        for diagnostic: Diagnostic in mir.errors {
                            io.eprintln(render_diagnostic(diagnostic))
                        }
                        if mir.errors.len() != 0 {
                            os.exit(1)
                        }
                        if command == "mir" {
                            io.println(render_mir(mir))
                        } else {
                            let emitter: LlvmTextEmitter =
                                new LlvmTextEmitter(
                                    mir,
                                    ir_comments_requested(),
                                    debug_build)
                            let emitted: string =
                                emitter.emit(
                                    command == "build" &&
                                    emit_kind == "bin")
                            for diagnostic: Diagnostic in
                                emitter.errors {
                                io.eprintln(
                                    render_diagnostic(
                                        diagnostic))
                            }
                            if emitter.errors.len() != 0 {
                                os.exit(1)
                            }
                            if command == "llvm" {
                                io.print(emitted)
                            } else {
                                var export_symbols: List<string> = []
                                for function: HirFunction in
                                    checker.hir.functions {
                                    if function.is_c_export {
                                        export_symbols.push(
                                            function.extern_name)
                                    }
                                }
                                let driver: NativeBuildDriver =
                                    new NativeBuildDriver(
                                        selected, cpu_name,
                                        runtime_profile,
                                        release, debug_build, lto,
                                        sysroot, compiler_path,
                                        linker,
                                        loader.link_arguments(
                                            selected),
                                        move export_symbols,
                                        encoding_bridge_features(
                                            loader.packages),
                                        log_bridge_required(
                                            loader.packages),
                                        net_bridge_features(
                                            loader.packages),
                                        csrc_selected(
                                            loader.csrc_rows,
                                            loader.cflag_rows,
                                            selected),
                                        emitter.unwind_enabled())
                                // The same module split into standalone
                                // chunks for the parallel backend, or an
                                // empty list when this build wants the one
                                // module it already has.
                                let chunks: List<string> =
                                    emitter.chunk_modules(
                                        native_chunk_count(
                                            emit_kind,
                                            selected.object_format,
                                            lto, debug_build,
                                            emitted.len()))
                                let built: bool =
                                    driver.build(
                                        file_path, emitted,
                                        emitter.ffi_source,
                                        output_path,
                                        emit_kind,
                                        ar_path,
                                        module_artifact_name(
                                            if loader.kind == "library" {
                                                loader.module_name
                                            } else {
                                                ""
                                            },
                                            file_path),
                                        chunks)
                                for diagnostic: Diagnostic in
                                    driver.errors {
                                    io.eprintln(
                                        render_diagnostic(
                                            diagnostic))
                                }
                                if !built { os.exit(1) }
                            }
                        }
                    } else {
                        let interpreter: TreeInterpreter =
                            new TreeInterpreter(
                                checker.hir,
                                move run_arguments)
                        if !interpreter.run() {
                            unsafe {
                                beans_out_flush()
                            }
                            io.eprintln(interpreter.panic_text)
                            os.exit(3)
                        }
                    }
                }
                if command == "layout" {
                    let engine: LayoutEngine =
                        new LayoutEngine(checker.hir, selected)
                    let valid_layouts: bool =
                        engine.validate_declarations()
                    var rendered: string = ""
                    if valid_layouts {
                        rendered = render_record_layouts(engine)
                    }
                    if rendered != "" { io.println(rendered) }
                    for diagnostic: Diagnostic in engine.errors {
                        io.println(render_diagnostic(diagnostic))
                    }
                    if !valid_layouts || engine.errors.len() != 0 {
                        os.exit(1)
                    }
                }
            }
        }
        return
    }

    var frontend_failed: bool = false
    for current_path: string in file_paths {
        var text: string = ""
        match fs.read(current_path) {
            ok(contents) => { text = contents }
            err(_) => {
                io.eprintln("error: can't open {current_path}")
                frontend_failed = true
                continue
            }
        }
        let source_id: int =
            sources.add(current_path, text)
        let source: SourceFile = sources.get(source_id)
        let lexer: Lexer = new Lexer(source.text)
        let tokens: List<Token> = lexer.scan()
        let token_count: int = tokens.len()
        if command == "lex" || command == "parse" {
            io.println("== {current_path}")
        }
        if command == "lex" {
            for token: Token in tokens {
                io.println(cli_token_line(token))
            }
            for diagnostic: Diagnostic in lexer.errors {
                io.eprintln(render_diagnostic(Diagnostic {
                    severity: diagnostic.severity,
                    file: source.path,
                    line: diagnostic.line,
                    col: diagnostic.col,
                    message: diagnostic.message,
                }))
            }
            io.println(
                "-- {token_count} tokens, {lexer.errors.len()} errors")
            io.println("")
            if lexer.errors.len() != 0 {
                frontend_failed = true
            }
        } else {
            let parser: Parser = new Parser(move tokens)
            let module: AstNode = parser.parse_module()
            if command == "parse" {
                io.print(render_cli_ast(module))
            } else {
                io.println(render_ast(module))
            }
            for diagnostic: Diagnostic in lexer.errors {
                if command == "parse" {
                    io.eprintln(render_diagnostic(Diagnostic {
                        severity: diagnostic.severity,
                        file: source.path,
                        line: diagnostic.line,
                        col: diagnostic.col,
                        message: diagnostic.message,
                    }))
                } else {
                    io.println(render_diagnostic(Diagnostic {
                        severity: diagnostic.severity,
                        file: source.path,
                        line: diagnostic.line,
                        col: diagnostic.col,
                        message: diagnostic.message,
                    }))
                }
            }
            for diagnostic: Diagnostic in parser.errors {
                if command == "parse" {
                    io.eprintln(render_diagnostic(Diagnostic {
                        severity: diagnostic.severity,
                        file: source.path,
                        line: diagnostic.line,
                        col: diagnostic.col,
                        message: diagnostic.message,
                    }))
                } else {
                    io.println(render_diagnostic(Diagnostic {
                        severity: diagnostic.severity,
                        file: source.path,
                        line: diagnostic.line,
                        col: diagnostic.col,
                        message: diagnostic.message,
                    }))
                }
            }
            if command == "parse" {
                var declaration_count: int = 0
                for child: AstNode in module.children {
                    if child.kind != "import" &&
                       child.kind != "package" &&
                       child.kind != "error" {
                        declaration_count += 1
                    }
                }
                io.println(
                    "-- {declaration_count} decls, {lexer.errors.len() + parser.errors.len()} errors")
                io.println("")
            }
            if parser.errors.len() != 0 ||
               lexer.errors.len() != 0 {
                frontend_failed = true
            }
        }
    }
    if frontend_failed { os.exit(1) }
}
