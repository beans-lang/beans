package main

import std.fs
import std.io
import std.os
import std.path

fn print_usage() {
    io.eprintln("usage: beansc <lex|parse|check|mir|run> <file.b>...")
    io.eprintln("       beansc build [options] <file.b> [-o out]")
    io.eprintln("       beansc bindgen <header.h> -o <bindings.b> [options] [-- clang-options]")
    io.eprintln("       beansc mod <tidy|update [module]>")
    io.eprintln("       beansc doctor")
    io.eprintln("       beansc lsp-probe <file.b>:<line>:<col>")
    io.eprintln("       beansc lsp   (language server on stdio)")
    io.eprintln("       beansc --version")
    io.eprintln("")
    io.eprintln("build options:")
    io.eprintln("  --release              -O3, NDEBUG")
    io.eprintln("  --lto                  link-time optimization")
    io.eprintln("  --target <triple>      {supported_target_names()}")
    io.eprintln("  --cpu <generic|native|name>")
    io.eprintln("  --features <+f,-f,...> enable or disable CPU features")
    io.eprintln("  --sysroot <path>       target sysroot for a cross link")
    io.eprintln("  --cc <path>            C driver to use (default clang)")
    io.eprintln("  --linker <name>        pass -fuse-ld=<name>")
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
    if command == "lsp" {
        if args.len() != 1 {
            io.eprintln("usage: beansc lsp")
            os.exit(2)
        }
        let status: int = run_self_lsp()
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
        var lock_mode: string = ""
        var update_module: string = ""
        if args.len() == 2 && args[1] == "tidy" {
            lock_mode = "tidy"
        } else if (args.len() == 2 || args.len() == 3) &&
                  args[1] == "update" {
            lock_mode = "update"
            if args.len() == 3 { update_module = args[2] }
        } else {
            print_usage()
            os.exit(2)
        }
        let entry: string = module_entry()
        if entry == "" {
            io.eprintln("error: run this command in a beans.pot project with a root .b file")
            os.exit(2)
        }
        let sources: SourceManager = new SourceManager()
        let loader: ModuleLoader =
            new ModuleLoader(sources, false, false,
                             lock_mode, update_module)
        let loaded: bool = loader.load(entry)
        if loaded {
            io.println("wrote beans.lock")
        }
        for diagnostic: Diagnostic in loader.errors {
            io.eprintln(render_diagnostic(diagnostic))
        }
        if !loaded { os.exit(1) }
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
                        new ExpressionChecker(checker)
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
                    if command == "mir" || command == "llvm" ||
                       command == "build" || command == "run" {
                        // Async bodies become synchronous task makers
                        // before either executor sees them. `check` skips
                        // this: expansion emits no user diagnostics.
                        let expander: AsyncExpander =
                            new AsyncExpander(checker)
                        if !expander.run() {
                            for diagnostic: Diagnostic in
                                expander.errors {
                                io.eprintln(
                                    render_diagnostic(diagnostic))
                            }
                            os.exit(1)
                        }
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
                                new LlvmTextEmitter(mir)
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
                                        release, lto,
                                        sysroot, compiler_path,
                                        linker,
                                        loader.link_arguments(
                                            selected),
                                        move export_symbols,
                                        encoding_bridge_features(
                                            loader.packages))
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
                                            file_path))
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
