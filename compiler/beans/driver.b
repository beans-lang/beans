import std.fs
import std.io
import std.os
import std.path
import std.process

class NativeBuildDriver {
    target: TargetDescription
    cpu: string
    runtime_profile: string
    release: bool
    lto: bool
    sysroot: string
    compiler: string
    linker: string
    link_arguments: List<string>
    export_symbols: List<string>
    errors: List<Diagnostic>

    fn init(target: TargetDescription,
            cpu: string,
            runtime_profile: string,
            release: bool,
            lto: bool,
            sysroot: string,
            compiler: string,
            linker: string,
            move link_arguments: List<string>,
            move export_symbols: List<string>) {
        self.target = target
        self.cpu = cpu
        self.runtime_profile = runtime_profile
        self.release = release
        self.lto = lto
        self.sysroot = sysroot
        self.compiler = compiler
        self.linker = linker
        self.link_arguments = move link_arguments
        self.export_symbols = move export_symbols
        self.errors = []
    }

    fn fail(file: string, message: string) {
        self.errors.push(Diagnostic {
            severity: Severity.error,
            file: file,
            line: 0,
            col: 0,
            message: message,
        })
    }

    fn configured_program(
        environment: string,
        fallback: string) -> string {
        match os.env(environment) {
            some(value) => {
                if value != "" { return value }
            }
            none => {}
        }
        return fallback
    }

    fn add_target_flags(command: process.Command) {
        // Alpine loses its startup-file search when its otherwise-correct musl
        // triple is forced explicitly. Omit it only on an actual musl host;
        // qemu-hosted cross compilers still need the target pinned.
        let native_musl: bool =
            self.target.env == "musl" &&
            self.target.triple == host_target_name()
        if !native_musl {
            command.arg("--target={self.target.llvm_triple()}")
        }
        if self.sysroot != "" {
            command.arg("--sysroot={self.sysroot}")
        }
        if self.cpu == "native" {
            command.arg("-march=native")
        } else if self.cpu != "generic" {
            // Naming CPU models with -march rather than -mcpu is a property of
            // the x86 family, not of the 64-bit target: -mcpu=pentium4 is not
            // accepted for i686.
            if self.target.arch == "x86_64" ||
               self.target.arch == "x86" {
                command.arg("-march={self.cpu}")
            } else {
                command.arg("-mcpu={self.cpu}")
            }
        }
        for feature: string in self.target.features {
            command.arg("-Xclang")
            command.arg("-target-feature")
            command.arg("-Xclang")
            command.arg("+{feature}")
        }
        for flag: string in self.target.c_driver_flags() {
            command.arg(flag)
        }
    }

    fn run_tool(command: process.Command,
                source: string,
                name: string) -> bool {
        match command.run() {
            ok(done) => {
                if done.ok() { return true }
                var message: string =
                    done.error_text().trim()
                if message == "" {
                    message =
                        "{name} failed (exit {done.status})"
                }
                self.fail(source, message)
            }
            err(error) => {
                self.fail(
                    source,
                    "cannot start {name}: {error.msg}")
            }
        }
        return false
    }

    fn compile_object(compiler: string,
                      source: string,
                      output: string,
                      pic: bool,
                      runtime_source: bool) -> bool {
        let command: process.Command =
            new process.Command(compiler)
        command.arg(
            if self.release { "-O3" } else { "-O2" })
        if self.release { command.arg("-DNDEBUG") }
        if self.lto { command.arg("-flto") }
        let wasi: bool = self.target.os == "wasi"
        if self.runtime_profile == "freestanding" ||
           wasi {
            command.arg("-ffreestanding")
            command.arg("-fno-stack-protector")
            command.arg("-D_FORTIFY_SOURCE=0")
        } else if self.target.os != "windows" {
            command.arg("-pthread")
        }
        if runtime_source {
            command.arg(
                if self.runtime_profile == "freestanding" ||
                   wasi {
                    "-DBEANS_RT_PROFILE=1"
                } else if self.runtime_profile == "minimal" {
                    "-DBEANS_RT_PROFILE=2"
                } else {
                    "-DBEANS_RT_PROFILE=3"
                })
            if wasi {
                command.arg("-DBEANS_RT_WASI=1")
            }
            command.arg(
                if self.target.has_decimal {
                    "-DBEANS_RT_DECIMAL=1"
                } else {
                    "-DBEANS_RT_DECIMAL=0"
                })
        }
        command.arg("-Wno-override-module")
        if pic {
            command.arg("-fPIC")
            command.arg("-fvisibility=hidden")
        }
        self.add_target_flags(command)
        command.arg("-c")
        command.arg(source)
        command.arg("-o")
        command.arg(output)
        return self.run_tool(
            command, source, "Clang")
    }

    fn runtime_cache_path(runtime: string,
                          pic: bool) -> string {
        var source: string = ""
        match fs.read(runtime) {
            ok(text) => { source = text }
            err(_) => {}
        }
        let key: string =
            "{self.target.triple}|{self.cpu}|{self.target.features.join(",")}|{self.runtime_profile}|{self.release}|{self.lto}|{pic}|{source}"
        var hash: int = 0
        for index: int in 0..key.len() {
            hash =
                (hash * 131 + key.byte_at(index)) %
                2147483647
        }
        let extension: string =
            if self.lto { "bc" } else { "o" }
        return path.join(
            "build",
            "beans_rt.{self.target.triple}.{hash}.{extension}")
    }

    fn cached_runtime_object(compiler: string,
                             runtime: string,
                             pic: bool) -> string {
        let object: string =
            self.runtime_cache_path(runtime, pic)
        if File.exists(object) { return object }
        if !self.compile_object(
               compiler, runtime, object, pic, true) {
            return ""
        }
        return object
    }

    fn build(source: string, llvm: string,
             ffi: string,
             written_output: string,
             emit: string,
             written_archiver: string,
             artifact_name: string) -> bool {
        var output: string = written_output
        if output == "" {
            if emit == "static" {
                output =
                    path.join(
                        "build",
                        "lib{artifact_name}.a")
            } else if emit == "shared" {
                if self.target.object_format == "wasm" {
                    output =
                        path.join(
                            "build",
                            "{artifact_name}.wasm")
                } else if self.target.object_format == "coff" {
                    output =
                        path.join(
                            "build",
                            "{artifact_name}.dll")
                } else {
                    let extension: string =
                        if self.target.os == "macos" {
                            "dylib"
                        } else {
                            "so"
                        }
                    output =
                        path.join(
                            "build",
                            "lib{artifact_name}.{extension}")
                }
            } else if emit == "obj" {
                output =
                    path.join(
                        "build",
                        "{artifact_name}.o")
            } else if emit == "bin" &&
                      self.target.object_format == "wasm" {
                output =
                    path.join(
                        "build",
                        "{artifact_name}.wasm")
            } else if emit == "bin" &&
                      self.target.object_format == "coff" {
                output = "{artifact_name}.exe"
            } else {
                output = artifact_name
            }
        }
        match Dir.make_all("build") {
            ok(_) => {}
            err(error) => {
                self.fail(
                    "build",
                    "cannot create build directory: {error.msg}")
                return false
            }
        }
        let ir_path: string =
            path.join(
                "build",
                "{artifact_name}.ll")
        match fs.write(ir_path, llvm) {
            ok(_) => {}
            err(error) => {
                self.fail(
                    ir_path,
                    "cannot write LLVM IR: {error.msg}")
                return false
            }
        }
        // extern "C" wrappers ride as generated C so Clang owns the
        // platform ABI classification
        var ffi_path: string = ""
        if ffi != "" {
            ffi_path =
                path.join(
                    "build",
                    "{artifact_name}_ffi.c")
            match fs.write(ffi_path, ffi) {
                ok(_) => {}
                err(error) => {
                    self.fail(
                        ffi_path,
                        "cannot write FFI wrappers: {error.msg}")
                    return false
                }
            }
        }
        if emit == "ir" {
            if written_output != "" &&
               written_output != ir_path {
                match fs.write(written_output, llvm) {
                    ok(_) => {}
                    err(error) => {
                        self.fail(
                            written_output,
                            "cannot write LLVM IR: {error.msg}")
                        return false
                    }
                }
                io.println("wrote {written_output}")
            } else {
                io.println("wrote {ir_path}")
            }
            return true
        }

        let runtime: string =
            self.configured_program(
                "BEANS_RUNTIME",
                "runtime/beans_rt.c")
        if !File.exists(runtime) {
            self.fail(
                runtime,
                "cannot find the Beans C runtime; set BEANS_RUNTIME")
            return false
        }
        let compiler: string =
            if self.compiler != "" {
                self.compiler
            } else if self.target.object_format == "wasm" {
                self.configured_program(
                    "BEANS_WASM_CC",
                    self.configured_program(
                        "BEANS_CC", "clang"))
            } else {
                self.configured_program("BEANS_CC", "clang")
            }

        if emit == "obj" {
            if !self.compile_object(
                    compiler, ir_path, output, false,
                    false) {
                return false
            }
            if ffi_path != "" {
                let ffi_object: string =
                    "{output}_ffi.o"
                if !self.compile_object(
                        compiler, ffi_path,
                        ffi_object, false, false) {
                    return false
                }
                io.println("built {ffi_object}")
            }
            io.println("built {output}")
            return true
        }

        if emit == "static" {
            let beans_object: string =
                "{output}.beans.o"
            let runtime_object: string =
                self.cached_runtime_object(
                    compiler, runtime, false)
            if runtime_object == "" { return false }
            if !self.compile_object(
                    compiler, ir_path,
                    beans_object, false, false) {
                return false
            }
            var ffi_object: string = ""
            if ffi_path != "" {
                ffi_object = "{output}.ffi.o"
                if !self.compile_object(
                        compiler, ffi_path,
                        ffi_object, false, false) {
                    return false
                }
            }
            let archiver: string =
                if written_archiver == "" {
                    "ar"
                } else {
                    written_archiver
                }
            let archive: process.Command =
                new process.Command(archiver)
            archive.arg("rcs")
            archive.arg(output)
            archive.arg(beans_object)
            archive.arg(runtime_object)
            if ffi_object != "" {
                archive.arg(ffi_object)
            }
            if !self.run_tool(
                    archive, source, "archiver") {
                return false
            }
            io.println("built {output}")
            return true
        }

        if (emit == "bin" || emit == "shared") &&
           self.target.object_format == "wasm" {
            let wasm_library: bool = emit == "shared"
            let wasi_wasm: bool = self.target.os == "wasi"
            if !wasm_library && !wasi_wasm {
                self.fail(
                    source,
                    "{self.target.triple} has no application host yet; use --emit shared for a browser/library module")
                return false
            }
            var wasm_host: string = ""
            if wasi_wasm {
                wasm_host =
                    self.configured_program(
                        "BEANS_WASM_HOST",
                        "runtime/wasm_host.c")
                if !File.exists(wasm_host) {
                    self.fail(
                        wasm_host,
                        "cannot find the Beans WASM host; set BEANS_WASM_HOST")
                    return false
                }
            }
            let wasm: process.Command =
                new process.Command(compiler)
            wasm.arg(
                if self.release { "-O3" } else { "-O2" })
            if self.release { wasm.arg("-DNDEBUG") }
            if self.lto { wasm.arg("-flto") }
            wasm.arg("-nostdlib")
            wasm.arg("-ffreestanding")
            wasm.arg("-fno-stack-protector")
            wasm.arg("-D_FORTIFY_SOURCE=0")
            wasm.arg("-DBEANS_RT_PROFILE=1")
            if wasi_wasm {
                wasm.arg("-DBEANS_RT_WASI=1")
            }
            wasm.arg("-DBEANS_RT_DECIMAL=1")
            if wasm_library {
                wasm.arg("-DBEANS_WASM_LIBRARY=1")
            }
            wasm.arg("-Wno-override-module")
            self.add_target_flags(wasm)
            if self.linker != "" {
                wasm.arg("-fuse-ld={self.linker}")
            }
            wasm.arg(ir_path)
            if ffi_path != "" { wasm.arg(ffi_path) }
            wasm.arg(runtime)
            if wasi_wasm { wasm.arg(wasm_host) }
            for argument: string in self.link_arguments {
                wasm.arg(argument)
            }
            if wasi_wasm { wasm.arg("-lc") }
            wasm.arg("-Wl,--no-entry")
            if wasm_library {
                wasm.arg("-Wl,--export-memory")
                wasm.arg("-Wl,--allow-undefined")
                wasm.arg("-Wl,--import-undefined")
                for symbol: string in self.export_symbols {
                    wasm.arg("-Wl,--export={symbol}")
                }
            } else {
                wasm.arg("-Wl,--export=_start")
            }
            wasm.arg("-o")
            wasm.arg(output)
            if !self.run_tool(
                    wasm, source, "Clang") {
                return false
            }
            io.println("built {output}")
            return true
        }

        var command: process.Command =
            new process.Command(compiler)
        let runtime_object: string =
            self.cached_runtime_object(
                compiler, runtime, emit == "shared")
        if runtime_object == "" { return false }
        command.arg(
            if self.release { "-O3" } else { "-O2" })
        if self.release { command.arg("-DNDEBUG") }
        if self.lto { command.arg("-flto") }
        if self.runtime_profile == "freestanding" {
            command.arg("-ffreestanding")
            command.arg("-fno-stack-protector")
            command.arg("-D_FORTIFY_SOURCE=0")
            command.arg("-DBEANS_RT_PROFILE=1")
        } else if self.target.os != "windows" {
            command.arg("-pthread")
        }
        // GNU/gnullvm Windows builds keep compiler support code in one PE file.
        if self.target.object_format == "coff" &&
           self.target.env != "msvc" &&
           emit == "bin" {
            command.arg("-static")
        }
        command.arg("-Wno-override-module")
        if emit == "shared" {
            command.arg("-fPIC")
            command.arg("-fvisibility=hidden")
            if self.target.os == "macos" {
                command.arg("-dynamiclib")
            } else {
                command.arg("-shared")
            }
        }
        self.add_target_flags(command)
        if self.linker != "" {
            command.arg("-fuse-ld={self.linker}")
        }
        command.arg(ir_path)
        if ffi_path != "" {
            command.arg(ffi_path)
        }
        command.arg(runtime_object)
        for argument: string in self.link_arguments {
            command.arg(argument)
        }
        if self.target.os != "windows" { command.arg("-lm") }
        // A 32-bit Linux target does 64-bit atomics on the reference count, and
        // Clang lowers a 64-bit atomic it cannot prove 8-aligned to a
        // `__atomic_*_8` libcall (i686 keeps them lock-free through CMPXCHG8B, but
        // the call still has to resolve). libatomic supplies those and exists in
        // every 32-bit Linux sysroot; 64-bit Linux resolves them inline.
        if self.target.os == "linux" &&
           self.target.pointer_bits == 32 {
            command.arg("-latomic")
        }
        // The runtime's socket section rides Winsock. This has to come *after*
        // the objects that reference it: GNU ld resolves an archive left to
        // right and only pulls members that satisfy already-undefined symbols,
        // so a -l ahead of its callers contributes nothing and every Winsock
        // symbol goes unresolved. lld scans the whole set and does not care,
        // which is why the wrong order survived a gate that always passes
        // --linker lld.
        if self.target.object_format == "coff" {
            command.arg("-lws2_32")
        }
        command.arg("-o")
        command.arg(output)
        if !self.run_tool(
                command, source, "Clang") {
            return false
        }
        io.println("built {output}")
        return true
    }
}
