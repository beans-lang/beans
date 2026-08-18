package main

import std.fs
import std.io
import std.os
import std.path
import std.process
import std.random
import std.time

// ---- std.encoding native bridges ----
//
// Each std.encoding package with a native side (json, xml, base64) maps to
// one bridge translation unit under runtime/encoding that includes its
// vendored library. Importing a package pulls exactly its own cached bridge
// object into the link; a program with no encoding import links none of
// them, so hello-world binaries carry no encoding code. The cache key covers
// the bridge and vendor file contents, so a vendored upgrade can never reuse
// a stale object.

fn encoding_source_root() -> string {
    match os.env("BEANS_ENCODING") {
        some(root) => {
            if root != "" { return root }
        }
        none => {}
    }
    if Dir.exists("runtime/encoding") { return "runtime/encoding" }
    return path.join(path.parent(stdlib_root()), "encoding")
}

// Bump when the request-buffer layouts, the status codes, or the entry-point
// set change. A cached object built against an older contract can then never
// be reused by a compiler that speaks the newer one.
fn encoding_bridge_abi() -> string {
    return "enc-abi-3"
}

fn encoding_bridge_is_cxx(feature: string) -> bool {
    return feature == "xml" || feature == "base64"
}

// The C driver's own identity, so a compiler upgrade or a different clang on
// PATH cannot reuse objects built by the previous one. Falls back to the
// path alone when the version cannot be read, which is still stronger than
// omitting it.
fn encoding_compiler_identity(compiler: string) -> string {
    let probe: process.Command = new process.Command(compiler)
    probe.arg("--version")
    match probe.run() {
        ok(done) => {
            if done.succeeded() {
                return "{compiler}|{done.stdout_text().trim()}"
            }
        }
        err(_) => {}
    }
    return "{compiler}|unknown-version"
}

fn encoding_bridge_translation_unit(root: string, feature: string) -> string {
    if feature == "json" {
        return path.join(root, "beans_enc_json.c")
    }
    if feature == "xml" {
        return path.join(root, "beans_enc_xml.cpp")
    }
    return path.join(root, "beans_enc_base64.cpp")
}

// Every file whose content shapes the compiled bridge, translation unit
// first. All of them feed the cache key.
fn encoding_bridge_inputs(root: string, feature: string) -> List<string> {
    var files: List<string> = []
    files.push(encoding_bridge_translation_unit(root, feature))
    files.push(path.join(root, "beans_enc_common.h"))
    if feature == "json" {
        files.push(path.join(root, "vendor/yyjson/yyjson.c"))
        files.push(path.join(root, "vendor/yyjson/yyjson.h"))
    } else if feature == "xml" {
        files.push(path.join(root, "beans_enc_pugixml_shim.h"))
        files.push(path.join(root, "vendor/pugixml/pugixml.cpp"))
        files.push(path.join(root, "vendor/pugixml/pugixml.hpp"))
        files.push(path.join(root, "vendor/pugixml/pugiconfig.hpp"))
    } else {
        files.push(path.join(root, "vendor/simdutf/simdutf.cpp"))
        files.push(path.join(root, "vendor/simdutf/simdutf.h"))
    }
    return move files
}

// The feature owning one beans_enc_* symbol, or "" for a symbol no bridge
// provides. The interpreter uses this to load a bridge on first call.
fn encoding_feature_for_symbol(symbol: string) -> string {
    if symbol.starts_with("beans_enc_json_") { return "json" }
    if symbol.starts_with("beans_enc_xml_") { return "xml" }
    if symbol.starts_with("beans_enc_b64_") { return "base64" }
    return ""
}

// Which std.encoding features the loaded program imports, in load order.
// std.encoding.binary is pure Beans and needs no bridge.
fn encoding_bridge_features(packages: List<LoadedPackage>) -> List<string> {
    var features: List<string> = []
    for loaded: LoadedPackage in packages {
        if loaded.import_path.starts_with("std.encoding.") {
            let feature: string =
                loaded.import_path.slice(13, loaded.import_path.len())
            if feature == "json" || feature == "xml" ||
               feature == "base64" {
                if !features.contains(feature) {
                    features.push(feature)
                }
            }
        }
    }
    return move features
}

class NativeBuildDriver {
    target: TargetDescription
    cpu: string
    runtime_profile: string
    release: bool
    // A build made to be looked at: no optimization, frame pointers kept, no
    // link-time optimization, and the platform's debug information asked for.
    // It never turns on with --release; the two are opposite requests.
    debug: bool
    lto: bool
    sysroot: string
    compiler: string
    linker: string
    link_arguments: List<string>
    export_symbols: List<string>
    encoding_features: List<string>
    errors: List<Diagnostic>

    fn init(target: TargetDescription,
            cpu: string,
            runtime_profile: string,
            release: bool,
            debug: bool,
            lto: bool,
            sysroot: string,
            compiler: string,
            linker: string,
            move link_arguments: List<string>,
            move export_symbols: List<string>,
            move encoding_features: List<string>) {
        self.target = target
        self.cpu = cpu
        self.runtime_profile = runtime_profile
        self.release = release
        self.debug = debug
        // A debug build with link-time optimization is not a debug build:
        // LTO is what erases the boundaries a person is trying to look at.
        self.lto = lto && !debug
        self.sysroot = sysroot
        self.compiler = compiler
        self.linker = linker
        self.link_arguments = move link_arguments
        self.export_symbols = move export_symbols
        self.encoding_features = move encoding_features
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

    // A native build is the one command that needs software Beans does not
    // ship in every package. When it is missing, say so before Clang is
    // started: a user should never have to read "cannot start Clang: No such
    // file or directory" — or worse, a linker error about a missing SDK — to
    // learn that they need one command.
    fn check_toolchain(source: string,
                       compiler: string) -> bool {
        if doctor_resolve(compiler) == "" {
            let fix: string =
                if host_target_name().contains("darwin") {
                    "install Apple Command Line Tools: xcode-select --install"
                } else if host_target_name().contains("windows") {
                    "install Clang, or install the full Beans package that bundles it"
                } else {
                    "install clang and lld (Debian/Ubuntu: sudo apt-get install clang lld), or install the full Beans package that bundles them"
                }
            self.fail(
                source,
                "cannot find the C compiler '{compiler}'. Beans emits LLVM IR, so it needs Clang; GCC cannot compile it. To fix: {fix}. Run 'beansc doctor' for the full report.")
            return false
        }
        // Apple's SDK cannot be bundled, so a macOS package always links
        // against the one on the machine. Ask for it by name rather than let
        // the user meet a missing-header error.
        if self.target.os == "macos" &&
           host_target_name().contains("darwin") {
            let developer: string =
                doctor_tool_line("xcode-select", "-p")
            if developer == "" || !Dir.exists(developer) {
                self.fail(
                    source,
                    "the macOS Command Line Tools are not installed, so there is no SDK to link against. To fix: xcode-select --install. Run 'beansc doctor' for the full report.")
                return false
            }
        }
        return true
    }

    // The target-selection flags as a list, so a caller that needs to hash
    // them (the encoding bridge cache) sees exactly what add_target_flags
    // passes to Clang.
    fn target_flag_list() -> List<string> {
        var flags: List<string> = []
        let native_musl: bool =
            self.target.env == "musl" &&
            self.target.triple == host_target_name()
        if !native_musl {
            flags.push("--target={self.target.llvm_triple()}")
        }
        if self.sysroot != "" {
            flags.push("--sysroot={self.sysroot}")
        }
        if self.cpu == "native" {
            flags.push("-march=native")
        } else if self.cpu != "generic" {
            if self.target.arch == "x86_64" ||
               self.target.arch == "x86" {
                flags.push("-march={self.cpu}")
            } else {
                flags.push("-mcpu={self.cpu}")
            }
        }
        for feature: string in self.target.features {
            flags.push("-Xclang")
            flags.push("-target-feature")
            flags.push("-Xclang")
            flags.push("+{feature}")
        }
        for flag: string in self.target.c_driver_flags() {
            flags.push(flag)
        }
        return move flags
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
                if done.succeeded() { return true }
                var message: string =
                    done.stderr_text().trim()
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

    // -O0 in a debug build: an optimized build reorders and inlines away the
    // very code a person set out to look at.
    fn optimization_flag() -> string {
        if self.debug { return "-O0" }
        if self.release { return "-O3" }
        return "-O2"
    }

    // What the platform's debugger needs. `-g` is the portable spelling; on
    // macOS and Linux clang writes DWARF, and on Windows targeting MSVC it
    // writes CodeView, both from this one flag. Frame pointers are kept so a
    // stack can be walked without unwind tables.
    fn debug_flags() -> List<string> {
        var flags: List<string> = []
        if !self.debug { return move flags }
        flags.push("-g")
        flags.push("-fno-omit-frame-pointer")
        return move flags
    }

    fn compile_object(compiler: string,
                      source: string,
                      output: string,
                      pic: bool,
                      runtime_source: bool) -> bool {
        let command: process.Command =
            new process.Command(compiler)
        command.arg(self.optimization_flag())
        if self.release { command.arg("-DNDEBUG") }
        for flag: string in self.debug_flags() {
            command.arg(flag)
        }
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

    // Every flag the bridge compile uses, in the order the command line
    // takes them. One list feeds both the cache key and the invocation, so a
    // flag can never change the object without changing its cache path.
    //
    // The C++ bridges build with no exceptions and no RTTI; simdutf runs in
    // upstream's SIMDUTF_NO_LIBCXX mode and pugixml carries a narrow shim
    // inside its own object, so the plain C driver links both with no C++
    // standard library. -fvisibility=hidden keeps vendored internals out of
    // the symbol table; the beans_enc_* API opts back in from the source.
    fn encoding_compile_flags(feature: string,
                              pic: bool) -> List<string> {
        var flags: List<string> = []
        if encoding_bridge_is_cxx(feature) {
            flags.push("-x")
            flags.push("c++")
            flags.push("-std=c++17")
            flags.push("-fno-exceptions")
            flags.push("-fno-rtti")
        }
        flags.push(self.optimization_flag())
        if self.release { flags.push("-DNDEBUG") }
        for flag: string in self.debug_flags() {
            flags.push(flag)
        }
        if self.lto { flags.push("-flto") }
        let wasi: bool = self.target.os == "wasi"
        if wasi {
            flags.push("-fno-stack-protector")
            flags.push("-D_FORTIFY_SOURCE=0")
        } else if self.target.os != "windows" {
            flags.push("-pthread")
        }
        flags.push("-fvisibility=hidden")
        if pic { flags.push("-fPIC") }
        for flag: string in self.target_flag_list() {
            flags.push(flag)
        }
        return move flags
    }

    fn compile_encoding_object(compiler: string,
                               source: string,
                               output: string,
                               feature: string,
                               pic: bool) -> bool {
        let command: process.Command =
            new process.Command(compiler)
        for flag: string in
            self.encoding_compile_flags(feature, pic) {
            command.arg(flag)
        }
        command.arg("-c")
        command.arg(source)
        command.arg("-o")
        command.arg(output)
        return self.run_tool(command, source, "Clang")
    }

    // The cache key covers everything that can change the emitted object:
    // the bridge ABI contract, the target and its CPU/feature selection, the
    // runtime profile, PIC/LTO/release mode, the exact compiler and its
    // version, every effective compile flag, and the full contents of the
    // bridge and vendored sources.
    fn encoding_cache_path(compiler: string,
                           root: string,
                           feature: string,
                           pic: bool) -> string {
        var blob: string = encoding_bridge_abi()
        blob = "{blob}|{feature}"
        blob = "{blob}|{self.target.triple}|{self.target.llvm_triple()}"
        blob = "{blob}|{self.cpu}|{self.target.features.join(",")}"
        blob = "{blob}|{self.runtime_profile}|{self.release}|{self.debug}|{self.lto}|{pic}"
        blob = "{blob}|{self.sysroot}"
        blob =
            "{blob}|{encoding_compiler_identity(compiler)}"
        blob =
            "{blob}|{self.encoding_compile_flags(feature, pic).join(" ")}"
        for input: string in encoding_bridge_inputs(root, feature) {
            match fs.read(input) {
                ok(text) => { blob = "{blob}|{text}" }
                err(_) => { blob = "{blob}|missing:{input}" }
            }
        }
        // Two independent 31-bit rolling hashes with different multipliers.
        // A single one over multi-megabyte vendored sources leaves too few
        // bits for a cache that must never serve a wrong object.
        var hash: int = 0
        var mixed: int = 0
        for index: int in 0..blob.len() {
            let byte: int = blob.byte_at(index)
            hash = (hash * 131 + byte) % 2147483647
            mixed = (mixed * 16777619 + byte + index % 7) % 2147483629
        }
        let extension: string =
            if self.lto { "bc" } else { "o" }
        return path.join(
            "build",
            "beans_enc_{feature}.{self.target.triple}.{hash}x{mixed}.{extension}")
    }

    fn cached_encoding_object(compiler: string,
                              root: string,
                              feature: string,
                              pic: bool) -> string {
        let object: string =
            self.encoding_cache_path(
                compiler, root, feature, pic)
        if File.exists(object) { return object }
        let source: string =
            encoding_bridge_translation_unit(root, feature)
        if !File.exists(source) {
            self.fail(
                source,
                "cannot find the std.encoding.{feature} bridge sources; set BEANS_ENCODING to the directory holding runtime/encoding")
            return ""
        }
        var staging: string = object
        match random.bytes(8) {
            ok(seed) => {
                staging = "{object}.{seed.get_u64(0)}"
            }
            err(_) => {
                staging = "{object}.{time.wall_millis()}"
            }
        }
        if !self.compile_encoding_object(
               compiler, source, staging, feature, pic) {
            return ""
        }
        match File.rename(staging, object) {
            ok(_) => {}
            err(_) => {
                match File.remove(staging) {
                    ok(_) => {}
                    err(_) => {}
                }
            }
        }
        return object
    }

    // One cached object per imported encoding feature, or an empty list
    // with a diagnostic recorded. The freestanding profile has no C library
    // for the bridges to stand on, so it is refused by name here rather
    // than surfacing as undefined libc symbols at link time.
    fn cached_encoding_objects(compiler: string,
                               pic: bool) -> List<string> {
        var objects: List<string> = []
        if self.encoding_features.len() == 0 {
            return move objects
        }
        if self.runtime_profile == "freestanding" {
            self.fail(
                "std.encoding",
                "std.encoding.{self.encoding_features[0]} needs --runtime full or minimal; the freestanding profile has no C library for the encoding bridges")
            return move objects
        }
        let root: string = encoding_source_root()
        var failed: bool = false
        for feature: string in self.encoding_features {
            if !failed {
                let object: string =
                    self.cached_encoding_object(
                        compiler, root, feature, pic)
                if object == "" {
                    failed = true
                } else {
                    objects.push(object)
                }
            }
        }
        if failed { objects.clear() }
        return move objects
    }

    fn runtime_cache_path(runtime: string,
                          pic: bool) -> string {
        var source: string = ""
        match fs.read(runtime) {
            ok(text) => { source = text }
            err(_) => {}
        }
        let key: string =
            "{self.target.triple}|{self.cpu}|{self.target.features.join(",")}|{self.runtime_profile}|{self.release}|{self.debug}|{self.lto}|{pic}|{source}"
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
        // Compile to a per-invocation name and rename into the cache:
        // two concurrent cold-cache builds must not interleave writes
        // into one object the linker is about to read.
        var staging: string = object
        match random.bytes(8) {
            ok(seed) => {
                staging = "{object}.{seed.get_u64(0)}"
            }
            err(_) => {
                staging = "{object}.{time.wall_millis()}"
            }
        }
        if !self.compile_object(
               compiler, runtime, staging, pic, true) {
            return ""
        }
        match File.rename(staging, object) {
            ok(_) => {}
            err(_) => {
                // a concurrent build already published the same content
                match File.remove(staging) {
                    ok(_) => {}
                    err(_) => {}
                }
            }
        }
        return object
    }

    // Concurrent lanes of one build configuration share identical IR
    // and therefore one scratch path; write through a private tmp and
    // rename so a racing reader always sees whole content.
    fn publish_scratch(target: string, text: string) -> bool {
        var tmp: string = "{target}.tmp"
        match random.bytes(8) {
            ok(seed) => {
                tmp = "{target}.tmp{seed.get_u64(0)}"
            }
            err(_) => {
                tmp = "{target}.tmp{time.wall_millis()}"
            }
        }
        match fs.write(tmp, text) {
            ok(_) => {}
            err(error) => {
                self.fail(
                    tmp,
                    "cannot write build scratch: {error.msg}")
                return false
            }
        }
        match File.rename(tmp, target) {
            ok(_) => { return true }
            err(_) => {}
        }
        match File.remove(tmp) {
            ok(_) => {}
            err(_) => {}
        }
        return File.exists(target)
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
        match Dir.create_all("build") {
            ok(_) => {}
            err(error) => {
                self.fail(
                    "build",
                    "cannot create build directory: {error.msg}")
                return false
            }
        }
        // Concurrent builds of entries sharing a stem — every project's
        // main.b, say — must not share scratch files, or interleaved
        // writes hand Clang a torn module. The transient name is
        // addressed by the IR's own content: deterministic for
        // identical builds (ELF objects embed the input filename as an
        // STT_FILE symbol, so a random name would break byte-identical
        // rebuilds) and distinct for concurrent different builds.
        // `--emit ir` keeps the stable spelling.
        var scratch_tag: string = ""
        if emit != "ir" {
            var ir_hash: int = 0
            for index: int in 0..llvm.len() {
                ir_hash =
                    (ir_hash * 131 + llvm.byte_at(index)) %
                    2147483647
            }
            scratch_tag = ".{ir_hash}x{llvm.len()}"
        }
        let ir_path: string =
            path.join(
                "build",
                "{artifact_name}{scratch_tag}.ll")
        if !self.publish_scratch(ir_path, llvm) {
            return false
        }
        // the stable spelling persists as an inspectable copy — tests
        // and humans read build/<name>.ll after a build — while Clang
        // always compiles the content-addressed file above, so
        // concurrent builds can tear this copy without tearing a compile
        if scratch_tag != "" {
            match fs.write(
                path.join("build", "{artifact_name}.ll"), llvm) {
                ok(_) => {}
                err(_) => {}
            }
        }
        // extern "C" wrappers ride as generated C so Clang owns the
        // platform ABI classification
        var ffi_path: string = ""
        if ffi != "" {
            ffi_path =
                path.join(
                    "build",
                    "{artifact_name}{scratch_tag}_ffi.c")
            if !self.publish_scratch(ffi_path, ffi) {
                return false
            }
            if scratch_tag != "" {
                match fs.write(
                    path.join(
                        "build",
                        "{artifact_name}_ffi.c"), ffi) {
                    ok(_) => {}
                    err(_) => {}
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
        if !self.check_toolchain(source, compiler) {
            return false
        }

        // Imported std.encoding features become cached bridge objects here,
        // once, and every emit path below links exactly this list.
        var encoding_objects: List<string> = []
        if self.encoding_features.len() != 0 {
            let recorded: int = self.errors.len()
            encoding_objects =
                self.cached_encoding_objects(
                    compiler, emit == "shared")
            if self.errors.len() != recorded {
                return false
            }
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
            // An object build's consumer owns the final link, so the bridge
            // objects are placed beside the output under stable names.
            for index: int in 0..encoding_objects.len() {
                let member: string =
                    "{output}_enc_{self.encoding_features[index]}.o"
                match fs.copy(encoding_objects[index], member) {
                    ok(_) => { io.println("built {member}") }
                    err(error) => {
                        self.fail(
                            member,
                            "cannot place encoding bridge object: {error.msg}")
                        return false
                    }
                }
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
            // A full release package bundles llvm-ar and its launcher names it
            // through BEANS_AR, the same way BEANS_CC names the bundled clang.
            let archiver: string =
                if written_archiver == "" {
                    self.configured_program("BEANS_AR", "ar")
                } else {
                    written_archiver
                }
            let archive: process.Command =
                new process.Command(archiver)
            archive.arg("rcs")
            archive.arg(output)
            archive.arg(beans_object)
            archive.arg(runtime_object)
            for encoding_object: string in encoding_objects {
                archive.arg(encoding_object)
            }
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
            wasm.arg(self.optimization_flag())
            if self.release { wasm.arg("-DNDEBUG") }
            for flag: string in self.debug_flags() {
                wasm.arg(flag)
            }
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
            for encoding_object: string in encoding_objects {
                wasm.arg(encoding_object)
            }
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
        command.arg(self.optimization_flag())
        if self.release { command.arg("-DNDEBUG") }
        for flag: string in self.debug_flags() {
            command.arg(flag)
        }
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
        for encoding_object: string in encoding_objects {
            command.arg(encoding_object)
        }
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
