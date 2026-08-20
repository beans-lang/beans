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

// ---- std.log native bridge ----

fn log_source_root() -> string {
    match os.env("BEANS_LOG") {
        some(root) => {
            if root != "" { return root }
        }
        none => {}
    }
    if Dir.exists("runtime/log") { return "runtime/log" }
    return path.join(path.parent(stdlib_root()), "log")
}

fn log_bridge_abi() -> string {
    return "log-abi-1"
}

fn log_bridge_inputs(root: string) -> List<string> {
    var files: List<string> = [
        path.join(root, "beans_log.cpp"),
        path.join(root, "beans_log.h"),
        path.join(root, "vendor/VENDOR.md"),
        path.join(root, "vendor/quill/LICENSE")]
    let include_root: string =
        path.join(root, "vendor/quill/include")
    match Dir.walk(include_root) {
        ok(entries) => {
            var names: List<string> = []
            for entry: string in entries {
                if entry.ends_with(".h") { names.push(entry) }
            }
            names.sort()
            for name: string in names {
                files.push(path.join(include_root, name))
            }
        }
        err(_) => {}
    }
    return move files
}

fn log_bridge_required(packages: List<LoadedPackage>) -> bool {
    for loaded: LoadedPackage in packages {
        if loaded.import_path == "std.log" { return true }
    }
    return false
}

fn log_bridge_link_arguments(
    enabled: bool, target_os: string,
    target_env: string) -> List<string> {
    var arguments: List<string> = []
    if !enabled { return move arguments }
    // The final link otherwise has only IR and object inputs, so plain clang
    // does not know it must add a C++ runtime. Driver mode lets each supported
    // toolchain choose its matching default: libc++ in LLVM-MinGW and on
    // macOS, libstdc++ in the Linux toolchains.
    if target_os != "windows" || target_env != "msvc" {
        arguments.push("-pthread")
    }
    arguments.push("--driver-mode=g++")
    return move arguments
}

fn log_symbol(symbol: string) -> bool {
    return symbol.starts_with("beans_log_")
}

// ---- runtime/net native bridges ----
//
// The networking stack follows the std.encoding shape exactly: each stdlib
// package with a native side maps to one bridge translation unit under
// runtime/net that includes its vendored library, compiled once per
// configuration and cached by content. Importing a package pulls exactly its
// own bridge object into the link; a program with no networking import links
// none of them. The one addition over encoding is per-feature link
// arguments, because the TLS and hash bridges stand on platform libraries
// (Security.framework, bcrypt) rather than vendored code alone.

fn net_source_root() -> string {
    match os.env("BEANS_NET") {
        some(root) => {
            if root != "" { return root }
        }
        none => {}
    }
    if Dir.exists("runtime/net") { return "runtime/net" }
    return path.join(path.parent(stdlib_root()), "net")
}

// Bump when a request-buffer layout, a status code, or the entry-point set
// changes, so an object built against the old contract is never reused.
fn net_bridge_abi() -> string {
    return "net-abi-4"
}

// C++ is per translation unit, by extension: a feature can mix its C++
// shim with vendored C sources (the ws bridge validates UTF-8 through
// simdutf while wslay itself is C).
fn net_source_is_cxx(source: string) -> bool {
    return source.ends_with(".cpp")
}

// import path -> bridge features. One import can pull more than one bridge:
// std.http owns both HTTP versions, so the h2 framing bridge rides with it.
fn net_bridge_features(packages: List<LoadedPackage>) -> List<string> {
    var features: List<string> = []
    for loaded: LoadedPackage in packages {
        var wanted: List<string> = []
        if loaded.import_path == "std.net" {
            wanted = ["sockx"]
        } else if loaded.import_path == "std.http" {
            wanted = ["h1", "h2"]
        } else if loaded.import_path == "std.websocket" {
            wanted = ["ws"]
        } else if loaded.import_path == "std.compress" {
            wanted = ["zlib"]
        } else if loaded.import_path == "std.crypto" {
            wanted = ["hash"]
        } else if loaded.import_path == "std.tls" {
            wanted = ["tls"]
        }
        for feature: string in wanted {
            if !features.contains(feature) {
                features.push(feature)
            }
        }
    }
    return move features
}

// The translation units one feature compiles, shim first. Vendored
// libraries whose sources cannot share a translation unit — colliding
// static helpers, or upstream files that disagree on internal signatures
// across files — compile beside the shim as their own objects, all inside
// the feature's one cache entry.
fn net_bridge_translation_units(root: string, feature: string) -> List<string> {
    var units: List<string> = []
    if feature == "h1" {
        units.push(path.join(root, "beans_net_h1.c"))
        units.push(path.join(root, "vendor/llhttp/llhttp.c"))
        return move units
    }
    if feature == "ws" {
        units.push(path.join(root, "beans_net_ws.cpp"))
        for input: string in net_bridge_inputs(root, feature) {
            if input.ends_with(".c") && input.contains("/vendor/") {
                units.push(input)
            }
        }
        return move units
    }
    if feature == "h2" || feature == "zlib" {
        units.push(path.join(root, "beans_net_{feature}.c"))
        for input: string in net_bridge_inputs(root, feature) {
            if input.ends_with(".c") && input.contains("/vendor/") {
                units.push(input)
            }
        }
        return move units
    }
    units.push(path.join(root, "beans_net_{feature}.c"))
    return move units
}

// Every file whose content shapes the compiled bridge — the shim, the
// shared header, and the vendored sources. All of them feed the cache key.
fn net_bridge_inputs(root: string, feature: string) -> List<string> {
    var files: List<string> = []
    if feature == "ws" {
        files.push(path.join(root, "beans_net_ws.cpp"))
    } else {
        files.push(path.join(root, "beans_net_{feature}.c"))
    }
    files.push(path.join(root, "beans_net_common.h"))
    if feature == "h1" {
        files.push(path.join(root, "vendor/llhttp/llhttp.h"))
        files.push(path.join(root, "vendor/llhttp/llhttp.c"))
        files.push(path.join(root, "vendor/llhttp/api.c"))
        files.push(path.join(root, "vendor/llhttp/http.c"))
    }
    if feature == "h2" {
        let lib: string = path.join(root, "vendor/nghttp2/lib")
        match Dir.list(lib) {
            ok(entries) => {
                var names: List<string> = []
                for entry: string in entries {
                    if entry.ends_with(".c") || entry.ends_with(".h") {
                        names.push(entry)
                    }
                }
                names.sort()
                for name: string in names {
                    files.push(path.join(lib, name))
                }
            }
            err(_) => {}
        }
        files.push(path.join(
            root, "vendor/nghttp2/lib/includes/nghttp2/nghttp2.h"))
        files.push(path.join(
            root, "vendor/nghttp2/lib/includes/nghttp2/nghttp2ver.h"))
    }
    if feature == "ws" {
        let lib: string = path.join(root, "vendor/wslay/lib")
        match Dir.list(lib) {
            ok(entries) => {
                var names: List<string> = []
                for entry: string in entries {
                    if entry.ends_with(".c") || entry.ends_with(".h") {
                        names.push(entry)
                    }
                }
                names.sort()
                for name: string in names {
                    files.push(path.join(lib, name))
                }
            }
            err(_) => {}
        }
        files.push(path.join(root, "vendor/wslay/lib/includes/wslay/wslay.h"))
        files.push(path.join(
            root, "vendor/wslay/lib/includes/wslay/wslayver.h"))
    }
    if feature == "zlib" {
        // The generated compat configuration is part of the contract, so it
        // feeds the key beside the upstream sources.
        for dir: string in ["zlib-config", "vendor/zlib-ng",
                            "vendor/zlib-ng/arch/generic"] {
            let lib: string = path.join(root, dir)
            match Dir.list(lib) {
                ok(entries) => {
                    var names: List<string> = []
                    for entry: string in entries {
                        if entry.ends_with(".c") || entry.ends_with(".h") {
                            names.push(entry)
                        }
                    }
                    names.sort()
                    for name: string in names {
                        files.push(path.join(lib, name))
                    }
                }
                err(_) => {}
            }
        }
    }
    return move files
}

// The feature owning one beans_* net symbol, or "" for a symbol no net
// bridge provides. The interpreter uses this to load a bridge on first call.
fn net_feature_for_symbol(symbol: string) -> string {
    if symbol.starts_with("beans_sockx_") { return "sockx" }
    if symbol.starts_with("beans_h1_") { return "h1" }
    if symbol.starts_with("beans_h2_") { return "h2" }
    if symbol.starts_with("beans_ws_") { return "ws" }
    if symbol.starts_with("beans_zlib_") { return "zlib" }
    if symbol.starts_with("beans_hash_") { return "hash" }
    if symbol.starts_with("beans_tls_") { return "tls" }
    return ""
}

// Include paths for the bridges whose vendored library is not amalgamated.
// nghttp2 and wslay both use angle includes of their own public headers, so
// the vendor include roots ride as -I flags, resolved against the net root.
fn net_bridge_include_flags(root: string, feature: string) -> List<string> {
    var flags: List<string> = []
    if feature == "zlib" {
        // zlib-ng's compat lane: the generated headers first, then the
        // vendor tree. The defines mirror upstream's cmake output for the
        // generic (no arch dispatch) build; the compiler-feature probes are
        // constants for Clang, the only C driver Beans uses.
        let config: string = path.join(root, "zlib-config")
        let lib: string = path.join(root, "vendor/zlib-ng")
        flags.push("-I{config}")
        flags.push("-I{lib}")
        flags.push("-DZLIB_COMPAT")
        flags.push("-DWITH_GZFILEOP")
        flags.push("-DWITH_ALL_FALLBACKS")
        flags.push("-DHAVE_ATTRIBUTE_ALIGNED")
        flags.push("-DHAVE_BUILTIN_ASSUME_ALIGNED")
        flags.push("-DHAVE_BUILTIN_CTZ")
        flags.push("-DHAVE_BUILTIN_CTZLL")
        flags.push("-DHAVE_VISIBILITY_HIDDEN")
        flags.push("-DHAVE_VISIBILITY_INTERNAL")
    }
    if feature == "h2" {
        let public: string = path.join(root, "vendor/nghttp2/lib/includes")
        let internal: string = path.join(root, "vendor/nghttp2/lib")
        flags.push("-I{public}")
        flags.push("-I{internal}")
    }
    if feature == "ws" {
        let public: string = path.join(root, "vendor/wslay/lib/includes")
        let internal: string = path.join(root, "vendor/wslay/lib")
        flags.push("-I{public}")
        flags.push("-I{internal}")
    }
    return move flags
}

// The vendored libraries normally get these defines from configure-generated
// headers. Beans builds their sources directly, so keep the small platform
// part of that configuration next to the shared include flags. Both native
// builds and the interpreter use this list.
fn net_bridge_platform_flags(
    feature: string, target_os: string,
    target_env: string) -> List<string> {
    var flags: List<string> = []
    if (feature == "h2" || feature == "ws") &&
       target_os != "windows" {
        flags.push("-DHAVE_ARPA_INET_H")
        flags.push("-DHAVE_NETINET_IN_H")
    }
    if feature == "ws" && target_os == "windows" {
        flags.push("-DHAVE_WINSOCK2_H")
    }
    if feature == "h2" && target_os == "windows" {
        // nghttp2's public header otherwise marks every call as dllimport.
        // We compile its vendored sources into the same executable or bridge
        // DLL, so these are static definitions, not a separate nghttp2 DLL.
        flags.push("-DNGHTTP2_STATICLIB")
    }
    // MSVC has ptrdiff_t but no POSIX ssize_t. nghttp2's implementation
    // still exposes its old ssize_t wrappers beside the newer ptrdiff_t API.
    if (feature == "h2" || feature == "ws") &&
       target_os == "windows" &&
       target_env == "msvc" {
        flags.push("-Dssize_t=ptrdiff_t")
    }
    if feature == "tls" && target_os == "macos" {
        flags.push("-fblocks")
    }
    return move flags
}

// Platform libraries a feature's bridge stands on, appended to the link and
// to the interpreter's bridge-library build. The hash and TLS bridges use
// the OS's own crypto rather than vendored implementations.
fn net_bridge_link_arguments(
    features: List<string>, target_os: string) -> List<string> {
    var arguments: List<string> = []
    if target_os == "windows" &&
       (features.contains("sockx") || features.contains("ws")) {
        // These bridge DLLs call Winsock directly. A final program already
        // links ws2_32 for the full runtime, but the interpreter builds each
        // bridge as a standalone DLL and must give that DLL its own import.
        arguments.push("-lws2_32")
    }
    if features.contains("tls") {
        if target_os == "macos" {
            arguments.push("-framework")
            arguments.push("Security")
            arguments.push("-framework")
            arguments.push("CoreFoundation")
            arguments.push("-framework")
            arguments.push("Network")
        }
        if target_os == "windows" {
            arguments.push("-lsecur32")
            arguments.push("-lcrypt32")
            arguments.push("-lncrypt")
        }
        if target_os == "linux" {
            // The OpenSSL backend loads libssl.so.3 at runtime; dlopen
            // lives in libdl on pre-2.34 glibc and is absorbed by libc
            // afterwards, where the flag is accepted and ignored.
            arguments.push("-ldl")
        }
    }
    if features.contains("hash") {
        if target_os == "windows" {
            arguments.push("-lbcrypt")
        }
        if target_os == "linux" {
            arguments.push("-ldl")
        }
    }
    return move arguments
}

// ---- the chunked parallel backend ----
//
// One clang on the compiler's own 25MB of IR is the longest single step of a
// self-build, and it uses one core while the other seven wait. `--emit bin`
// splits the module into standalone chunks, compiles them with concurrent
// clang processes, and links the objects.
//
// The chunk count is a constant, not the machine's core count. The partition
// decides which symbols land in which object and therefore the bytes of the
// final binary, and a binary must not depend on how many cores built it —
// the fixed-point gate compares binaries built on different runs, and people
// compare them across machines. BEANS_BUILD_JOBS only decides how many of
// those compiles run at once, so it changes the wall time and nothing else.
// Asking for one job asks for the single-module path instead.
fn native_chunk_count(emit: string,
                      object_format: string,
                      lto: bool,
                      debug: bool,
                      ir_bytes: int) -> int {
    if emit != "bin" { return 1 }
    // -flto hands the whole module to the linker anyway, and a wasm build
    // links through a different command entirely
    if lto { return 1 }
    if object_format == "wasm" { return 1 }
    // `--debug` asks for a build to look at, not a fast one, and on Darwin
    // the debug bundle is a step Clang only takes when it compiles and links
    // in one command. A build that wants a debugger keeps the whole module.
    if debug { return 1 }
    // Under a few megabytes one clang is already quick, and every chunk
    // repeats the declarations and costs its own process.
    if ir_bytes < 4194304 { return 1 }
    if native_build_jobs(native_chunk_limit()) == 1 {
        return 1
    }
    return native_chunk_limit()
}

fn native_chunk_limit() -> int {
    return 8
}

fn native_build_jobs(chunks: int) -> int {
    match os.env("BEANS_BUILD_JOBS") {
        some(value) => {
            let asked: int = value.trim().to_int().or(0)
            if asked >= 1 {
                if asked < chunks { return asked }
                return chunks
            }
        }
        none => {}
    }
    return chunks
}

// A cached object is trusted when the length it was published with is still
// its length. The cache is only ever written by renaming a finished file
// into place, so a half-written object cannot appear through normal use;
// this catches the one something else truncated, and re-compiles rather than
// handing the linker a file it cannot read. What it does not catch is a byte
// changed in place without changing the length — neither does any other
// cache here, and a malformed object still stops the link with the file
// named rather than reaching the binary.
fn native_chunk_receipt(object: string) -> string {
    return "{object}.len"
}

fn native_chunk_object_ready(object: string) -> bool {
    if !File.exists(object) { return false }
    var published: int = -1
    match fs.read(native_chunk_receipt(object)) {
        ok(text) => {
            published = text.trim().to_int().or(-1)
        }
        err(_) => {}
    }
    if published < 0 { return false }
    match File.size(object) {
        ok(size) => { return size == published }
        err(_) => { return false }
    }
}

// The object first, then its length: a reader that finds the receipt always
// finds the object it describes.
fn native_chunk_publish(staging: string, object: string) {
    csrc_publish(staging, object)
    match File.size(object) {
        ok(size) => {
            match fs.write(
                native_chunk_receipt(object), "{size}\n") {
                ok(_) => {}
                err(_) => {}
            }
        }
        err(_) => {}
    }
}

// Test-only native instrumentation. Keeping the accepted values closed
// avoids turning an environment variable into arbitrary compiler flags.
// These flags are part of every object cache key below, so a sanitized build
// can never reuse a normal bridge or runtime object.
fn sanitizer_flags() -> List<string> {
    var flags: List<string> = []
    var requested: string = ""
    match os.env("BEANS_SANITIZE") {
        some(value) => { requested = value }
        none => {}
    }
    if requested == "address,undefined" {
        flags.push("-fsanitize=address,undefined")
        flags.push("-fno-sanitize-recover=undefined")
        flags.push("-fno-omit-frame-pointer")
    } else if requested == "thread" {
        flags.push("-fsanitize=thread")
        flags.push("-fno-omit-frame-pointer")
    }
    return move flags
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
    log_enabled: bool
    net_features: List<string>
    csrc_sources: List<string>
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
            move encoding_features: List<string>,
            log_enabled: bool,
            move net_features: List<string>,
            move csrc_sources: List<string>) {
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
        self.log_enabled = log_enabled
        self.net_features = move net_features
        self.csrc_sources = move csrc_sources
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

    // 32-bit x86 is where -O0 stops being free. LLVM picks its fast register
    // allocator at -O0, and that allocator does not spill the way the greedy
    // one does: on a target with six usable general-purpose registers, where
    // every i64 costs a pair, it can genuinely run out. This compiler's
    // output reaches that point — `beansc build --target i686-pc-windows-gnu
    // examples/unsafe_raw.b` fails with "ran out of registers during register
    // allocation" in three functions at -O0 and builds clean at any level
    // that allocates with greedy. No 64-bit target and no ARM lane hits it;
    // they have the registers to spare.
    //
    // Naming the allocator directly is not a way out: `-mllvm
    // -regalloc=greedy` at -O0 stops the backend with "Must use fast
    // (default) register allocator for unoptimized regalloc". The
    // optimization level is the only lever.
    fn fast_regalloc_runs_out() -> bool {
        return self.target.arch == "x86" &&
               self.target.pointer_bits == 32
    }

    // A plain `beansc build` optimizes for the edit-build-run loop, not for
    // the binary it produces, so it runs no optimizer: on the compiler's own
    // 31MB of IR clang spends about nine seconds at -O2 and about two at -O0,
    // and that difference is most of what a developer waits for. `--release`
    // is the request for a fast binary. -O0 in a debug build is a separate
    // reason: an optimized build reorders and inlines away the very code a
    // person set out to look at.
    fn optimization_flag() -> string {
        if self.debug {
            // -Og is clang's -O1 pipeline chosen for debugging, which is as
            // close to -O0 as a 32-bit x86 build can get. Some of what a
            // person set out to look at will have moved; a build that cannot
            // compile would have hidden all of it.
            if self.fast_regalloc_runs_out() { return "-Og" }
            return "-O0"
        }
        if self.release { return "-O3" }
        // -O1 is the first level that allocates with greedy. The dev-loop
        // build time this costs is only ever paid by someone cross-building
        // for 32-bit x86, which is not a loop anyone edits in.
        if self.fast_regalloc_runs_out() { return "-O1" }
        return "-O0"
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
        for flag: string in sanitizer_flags() {
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
        for flag: string in sanitizer_flags() {
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

    // ---- std.log bridge object ----

    fn log_compile_flags(root: string,
                         pic: bool) -> List<string> {
        var flags: List<string> = [
            "-x", "c++", "-std=c++17", "-fexceptions", "-fno-rtti",
            self.optimization_flag()]
        if self.release { flags.push("-DNDEBUG") }
        for flag: string in self.debug_flags() {
            flags.push(flag)
        }
        for flag: string in sanitizer_flags() {
            flags.push(flag)
        }
        if self.lto { flags.push("-flto") }
        if self.target.os != "windows" ||
           self.target.env != "msvc" {
            flags.push("-pthread")
        }
        flags.push("-fvisibility=hidden")
        if pic { flags.push("-fPIC") }
        flags.push(
            if self.runtime_profile == "minimal" {
                "-DBEANS_RT_PROFILE=2"
            } else {
                "-DBEANS_RT_PROFILE=3"
            })
        flags.push("-I{root}")
        flags.push("-I{path.join(root, "vendor/quill/include")}")
        for flag: string in self.target_flag_list() {
            flags.push(flag)
        }
        return move flags
    }

    fn log_cache_path(compiler: string,
                      root: string,
                      pic: bool) -> string {
        var blob: string = log_bridge_abi()
        blob = "{blob}|{self.target.triple}|{self.target.llvm_triple()}"
        blob = "{blob}|{self.cpu}|{self.target.features.join(",")}"
        blob = "{blob}|{self.runtime_profile}|{self.release}|{self.debug}|{self.lto}|{pic}"
        blob = "{blob}|{self.sysroot}"
        blob = "{blob}|{encoding_compiler_identity(compiler)}"
        let include_root: string =
            path.join(root, "vendor/quill/include")
        for flag: string in self.log_compile_flags(root, pic) {
            if flag == "-I{root}" {
                blob = "{blob}|-I<log-root>"
            } else if flag == "-I{include_root}" {
                blob = "{blob}|-I<quill-include>"
            } else {
                blob = "{blob}|{flag}"
            }
        }
        for input: string in log_bridge_inputs(root) {
            match fs.read(input) {
                ok(text) => { blob = "{blob}|{text}" }
                err(_) => { blob = "{blob}|missing:{input}" }
            }
        }
        var hash: int = 0
        var mixed: int = 0
        for index: int in 0..blob.len() {
            let byte: int = blob.byte_at(index)
            hash = (hash * 131 + byte) % 2147483647
            mixed =
                (mixed * 16777619 + byte + index % 7) %
                2147483629
        }
        let extension: string = if self.lto { "bc" } else { "o" }
        return path.join(
            "build",
            "beans_log.{self.target.triple}.{hash}x{mixed}.{extension}")
    }

    fn cached_log_object(compiler: string,
                         pic: bool) -> string {
        if !self.log_enabled { return "" }
        if self.runtime_profile == "freestanding" ||
           self.target.object_format == "wasm" {
            self.fail(
                "std.log",
                "std.log needs a hosted full or minimal runtime with threads")
            return ""
        }
        let root: string = log_source_root()
        let source: string = path.join(root, "beans_log.cpp")
        if !File.exists(source) {
            self.fail(
                source,
                "cannot find the std.log bridge sources; set BEANS_LOG to the directory holding runtime/log")
            return ""
        }
        let object: string =
            self.log_cache_path(compiler, root, pic)
        if File.exists(object) { return object }
        var staging: string = object
        match random.bytes(8) {
            ok(seed) => { staging = "{object}.{seed.get_u64(0)}" }
            err(_) => { staging = "{object}.{time.wall_millis()}" }
        }
        let command: process.Command = new process.Command(compiler)
        for flag: string in self.log_compile_flags(root, pic) {
            command.arg(flag)
        }
        command.arg("-c")
        command.arg(source)
        command.arg("-o")
        command.arg(staging)
        if !self.run_tool(command, source, "Clang") {
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

    // ---- runtime/net bridge objects ----
    // The same contract as the encoding bridges: hidden visibility, cached
    // by content, staged then renamed. The only additions are per-feature
    // include flags (nghttp2 and wslay are not amalgamated) and the C++
    // lane for the ws bridge, which validates UTF-8 through simdutf.
    fn net_compile_flags(feature: string,
                         source: string,
                         pic: bool) -> List<string> {
        var flags: List<string> = []
        if net_source_is_cxx(source) {
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
        for flag: string in sanitizer_flags() {
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
        for flag: string in
            net_bridge_include_flags(net_source_root(), feature) {
            flags.push(flag)
        }
        for flag: string in
            net_bridge_platform_flags(
                feature, self.target.os, self.target.env) {
            flags.push(flag)
        }
        for flag: string in self.target_flag_list() {
            flags.push(flag)
        }
        return move flags
    }

    fn compile_net_object(compiler: string,
                          source: string,
                          output: string,
                          feature: string,
                          pic: bool) -> bool {
        let command: process.Command =
            new process.Command(compiler)
        for flag: string in
            self.net_compile_flags(feature, source, pic) {
            command.arg(flag)
        }
        command.arg("-c")
        command.arg(source)
        command.arg("-o")
        command.arg(output)
        return self.run_tool(command, source, "Clang")
    }

    // One cache key per (feature, translation unit); every unit's key still
    // hashes the feature's whole input set, so touching any vendored file
    // rebuilds every object of that feature.
    fn net_cache_path(compiler: string,
                      root: string,
                      feature: string,
                      source: string,
                      pic: bool) -> string {
        var blob: string = net_bridge_abi()
        blob = "{blob}|{feature}|{source}"
        blob = "{blob}|{self.target.triple}|{self.target.llvm_triple()}"
        blob = "{blob}|{self.cpu}|{self.target.features.join(",")}"
        blob = "{blob}|{self.runtime_profile}|{self.release}|{self.debug}|{self.lto}|{pic}"
        blob = "{blob}|{self.sysroot}"
        blob =
            "{blob}|{encoding_compiler_identity(compiler)}"
        blob =
            "{blob}|{self.net_compile_flags(feature, source, pic).join(" ")}"
        for input: string in net_bridge_inputs(root, feature) {
            match fs.read(input) {
                ok(text) => { blob = "{blob}|{text}" }
                err(_) => { blob = "{blob}|missing:{input}" }
            }
        }
        var hash: int = 0
        var mixed: int = 0
        for index: int in 0..blob.len() {
            let byte: int = blob.byte_at(index)
            hash = (hash * 131 + byte) % 2147483647
            mixed = (mixed * 16777619 + byte + index % 7) % 2147483629
        }
        let extension: string =
            if self.lto { "bc" } else { "o" }
        let stem: string = path.stem(source)
        return path.join(
            "build",
            "beans_net_{feature}.{stem}.{self.target.triple}.{hash}x{mixed}.{extension}")
    }

    fn cached_net_object(compiler: string,
                         root: string,
                         feature: string,
                         source: string,
                         pic: bool) -> string {
        let object: string =
            self.net_cache_path(
                compiler, root, feature, source, pic)
        if File.exists(object) { return object }
        if !File.exists(source) {
            self.fail(
                source,
                "cannot find the networking bridge sources for '{feature}'; set BEANS_NET to the directory holding runtime/net")
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
        if !self.compile_net_object(
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

    fn cached_net_objects(compiler: string,
                          pic: bool) -> List<string> {
        var objects: List<string> = []
        if self.net_features.len() == 0 {
            return move objects
        }
        if self.runtime_profile == "freestanding" {
            self.fail(
                "std.net",
                "the networking bridges need --runtime full; the freestanding profile has no C library for them to stand on")
            return move objects
        }
        let root: string = net_source_root()
        var failed: bool = false
        for feature: string in self.net_features {
            for source: string in
                net_bridge_translation_units(root, feature) {
                if !failed {
                    let object: string =
                        self.cached_net_object(
                            compiler, root, feature, source, pic)
                    if object == "" {
                        failed = true
                    } else {
                        objects.push(object)
                    }
                }
            }
        }
        if failed { objects.clear() }
        return move objects
    }

    // Stable per-object labels for the --emit obj copies, parallel to
    // cached_net_objects' return order.
    fn net_object_labels() -> List<string> {
        var labels: List<string> = []
        let root: string = net_source_root()
        for feature: string in self.net_features {
            for source: string in
                net_bridge_translation_units(root, feature) {
                labels.push("{feature}_{path.stem(source)}")
            }
        }
        return move labels
    }

    fn csrc_cache_path(compiler: string,
                       source: string,
                       pic: bool,
                       inputs: string) -> string {
        let key: string =
            "csrc|{csrc_compiler_identity(compiler)}|{self.target.triple}|{self.cpu}|{self.target.features.join(",")}|{self.runtime_profile}|{self.release}|{self.debug}|{self.lto}|{pic}|{sanitizer_flags().join(" ")}|{inputs}"
        let extension: string =
            if self.lto { "bc" } else { "o" }
        let stem: string = path.stem(source)
        return path.join(
            "build",
            "beans_csrc.{stem}.{self.target.triple}.{csrc_key_tag(key)}.{extension}")
    }

    fn cached_csrc_object(compiler: string,
                          source: string,
                          pic: bool) -> string {
        if !File.exists(source) {
            self.fail(
                source,
                "csrc file does not exist")
            return ""
        }
        var inputs: string = ""
        match csrc_dependency_key(source, []) {
            ok(key) => { inputs = key }
            err(error) => {
                self.fail(source, error.msg)
                return ""
            }
        }
        let object: string =
            self.csrc_cache_path(compiler, source, pic, inputs)
        if File.exists(object) { return object }
        let staging: string = csrc_staging_name(object)
        if !self.compile_object(
               compiler, source, staging, pic, false) {
            return ""
        }
        csrc_publish(staging, object)
        return object
    }

    fn cached_csrc_objects(compiler: string,
                           pic: bool) -> List<string> {
        var objects: List<string> = []
        var failed: bool = false
        for source: string in self.csrc_sources {
            let object: string =
                self.cached_csrc_object(
                    compiler, source, pic)
            if object == "" {
                failed = true
            } else {
                objects.push(object)
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
            "{self.target.triple}|{self.cpu}|{self.target.features.join(",")}|{self.runtime_profile}|{self.release}|{self.debug}|{self.lto}|{pic}|{sanitizer_flags().join(" ")}|{source}"
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

    // Everything a chunk compile passes Clang, in command-line order. One
    // list feeds both the cache key and the invocation, so a flag can never
    // change an object without changing its cache path. These are exactly the
    // compile-side flags the single-module link line carries: the link-only
    // ones — -fuse-ld, -static, -Wl, -l — have no place on a -c.
    fn chunk_compile_flags() -> List<string> {
        var flags: List<string> = []
        flags.push(self.optimization_flag())
        if self.release { flags.push("-DNDEBUG") }
        for flag: string in self.debug_flags() {
            flags.push(flag)
        }
        if self.runtime_profile == "freestanding" {
            flags.push("-ffreestanding")
            flags.push("-fno-stack-protector")
            flags.push("-D_FORTIFY_SOURCE=0")
            flags.push("-DBEANS_RT_PROFILE=1")
        } else if self.target.os != "windows" {
            flags.push("-pthread")
        }
        flags.push("-Wno-override-module")
        for flag: string in self.target_flag_list() {
            flags.push(flag)
        }
        return move flags
    }

    // The cache key covers everything that can change the emitted object: the
    // chunk's own IR, the target and its CPU/feature selection, the runtime
    // profile, optimization and debug mode, the exact compiler and its
    // version, every effective compile flag, and the compiler's own release
    // with the runtime ABI it speaks.
    //
    // The IR is folded into the same two hashes as the key rather than
    // pasted onto it: a chunk is megabytes, and joining them first would copy
    // every one of those bytes to hash them once.
    fn chunk_cache_key(identity: string,
                       flags: string,
                       text: string) -> string {
        let blob: string =
            "chunk-1|{self.target.triple}|{self.target.llvm_triple()}|{self.cpu}|{self.target.features.join(",")}|{self.runtime_profile}|{self.release}|{self.debug}|{self.lto}|{self.sysroot}|{identity}|{flags}|{compiler_banner()}"
        var hash: int = 0
        var mixed: int = 0
        for index: int in 0..blob.len() {
            let byte: int = blob.byte_at(index)
            hash = (hash * 131 + byte) % 2147483647
            mixed =
                (mixed * 16777619 + byte + index % 7) %
                2147483629
        }
        for index: int in 0..text.len() {
            let byte: int = text.byte_at(index)
            hash = (hash * 131 + byte) % 2147483647
            mixed =
                (mixed * 16777619 + byte + index % 7) %
                2147483629
        }
        return "{hash}x{mixed}"
    }

    // One object per chunk: reused when its key is already on disk, compiled
    // by one of the concurrent Clangs when it is not. The returned order is
    // the chunk order, never the order the compiles finished, so the link
    // line — and the binary — does not depend on the scheduler.
    fn cached_chunk_objects(compiler: string,
                            artifact_name: string,
                            chunks: List<string>) -> List<string> {
        var objects: List<string> = []
        let identity: string =
            encoding_compiler_identity(compiler)
        let flags: List<string> = self.chunk_compile_flags()
        let printed: string = flags.join(" ")
        var sources: List<string> = []
        var staged: List<string> = []
        var pending: int = 0
        var failed: bool = false
        for index: int in 0..chunks.len() {
            if failed { continue }
            let key: string =
                self.chunk_cache_key(
                    identity, printed, chunks[index])
            let stem: string =
                "beans_chunk.{artifact_name}.{self.target.triple}.{index}.{key}"
            let object: string =
                path.join("build", "{stem}.o")
            objects.push(object)
            if native_chunk_object_ready(object) {
                sources.push("")
                staged.push("")
                continue
            }
            let source: string =
                path.join("build", "{stem}.ll")
            // The name is addressed by the chunk's own content, so two
            // concurrent builds of the same program write the same bytes to
            // the same path and a third reading it sees whole content —
            // and object files that embed their input's filename still
            // rebuild byte for byte.
            if !self.publish_scratch(
                   source, chunks[index]) {
                failed = true
                continue
            }
            sources.push(source)
            staged.push(csrc_staging_name(object))
            pending += 1
        }
        if !failed && pending != 0 {
            failed =
                !self.compile_chunks(
                    compiler, flags, sources, staged,
                    native_build_jobs(chunks.len()))
        }
        if failed {
            objects.clear()
            return move objects
        }
        if pending == 0 { return move objects }
        for index: int in 0..chunks.len() {
            if staged[index] == "" { continue }
            native_chunk_publish(
                staged[index], objects[index])
            // the chunk module has done its job; a failed compile keeps
            // its own, which is the one worth looking at
            match File.remove(sources[index]) {
                ok(_) => {}
                err(_) => {}
            }
        }
        return move objects
    }

    // A `Child` owns a pid and three pipes, so it is move-only and can only
    // reach the list it is waited on from through a move. `?` is the spelling
    // that moves one out of the Result it arrives in.
    fn start_chunk(command: process.Command,
                   running: List<process.Child>) -> Result<int> {
        running.push(command.start()?)
        return ok(running.len())
    }

    // `jobs` Clangs at a time. They are started together and then waited for
    // in order, which is safe even though each one owns a pipe: a child that
    // fills its stderr only stops until its turn comes, and the child being
    // drained is never waiting on anyone.
    fn compile_chunks(compiler: string,
                      flags: List<string>,
                      sources: List<string>,
                      objects: List<string>,
                      jobs: int) -> bool {
        var succeeded: bool = true
        var next: int = 0
        for next < sources.len() {
            var running: List<process.Child> = []
            var names: List<string> = []
            var started: int = 0
            for started < jobs &&
                next < sources.len() {
                let source: string = sources[next]
                if source == "" {
                    next += 1
                    continue
                }
                let command: process.Command =
                    new process.Command(compiler)
                for flag: string in flags {
                    command.arg(flag)
                }
                command.arg("-c")
                command.arg(source)
                command.arg("-o")
                command.arg(objects[next])
                match self.start_chunk(
                          command, running) {
                    ok(_) => { names.push(source) }
                    err(error) => {
                        self.fail(
                            source,
                            "cannot start Clang: {error.msg}")
                        succeeded = false
                    }
                }
                next += 1
                started += 1
            }
            for index: int in 0..running.len() {
                var message: string = ""
                match running[index].stderr.read_to_end(
                          1048576) {
                    ok(text) => {
                        message = text.to_string().trim()
                    }
                    err(_) => {}
                }
                match running[index].wait() {
                    ok(status) => {
                        if status != 0 {
                            if message == "" {
                                message =
                                    "Clang failed (exit {status})"
                            }
                            self.fail(
                                names[index], message)
                            succeeded = false
                        }
                    }
                    err(error) => {
                        self.fail(
                            names[index],
                            "cannot wait for Clang: {error.msg}")
                        succeeded = false
                    }
                }
            }
        }
        return succeeded
    }

    fn build(source: string, llvm: string,
             ffi: string,
             written_output: string,
             emit: string,
             written_archiver: string,
             artifact_name: string,
             chunks: List<string>) -> bool {
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
        // The caller only prepares chunks for a build that can use them; the
        // rest of this decision is the driver's own, and repeating it here
        // keeps a caller that hands over chunks for an -flto or wasm build
        // from taking a path those cannot travel.
        let chunked: bool =
            emit == "bin" &&
            chunks.len() > 1 &&
            !self.lto &&
            !self.debug &&
            self.target.object_format != "wasm"
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
        if chunked {
            // Clang reads the chunks, each addressed by its own content, so
            // the whole module is only ever read by a person: one stable
            // copy, and none of the megabytes the transient one would cost.
            match fs.write(
                path.join("build", "{artifact_name}.ll"), llvm) {
                ok(_) => {}
                err(_) => {}
            }
        } else {
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

        // std.log is one cached C++ object. It is absent from programs that
        // do not import the package.
        var log_object: string = ""
        if self.log_enabled {
            let recorded: int = self.errors.len()
            log_object =
                self.cached_log_object(
                    compiler, emit == "shared")
            if self.errors.len() != recorded {
                return false
            }
        }

        // Imported networking packages become cached bridge objects the
        // same way, one per feature.
        var net_objects: List<string> = []
        if self.net_features.len() != 0 {
            let recorded: int = self.errors.len()
            net_objects =
                self.cached_net_objects(
                    compiler, emit == "shared")
            if self.errors.len() != recorded {
                return false
            }
        }

        // Manifest csrc rows compile with this build's own flags, cached
        // by content hash, and ride every emit path beside the bridges.
        var csrc_objects: List<string> = []
        if self.csrc_sources.len() != 0 {
            let recorded: int = self.errors.len()
            csrc_objects =
                self.cached_csrc_objects(
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
            if log_object != "" {
                let member: string = "{output}_log.o"
                match fs.copy(log_object, member) {
                    ok(_) => { io.println("built {member}") }
                    err(error) => {
                        self.fail(
                            member,
                            "cannot place std.log bridge object: {error.msg}")
                        return false
                    }
                }
            }
            let net_labels: List<string> = self.net_object_labels()
            for index: int in 0..net_objects.len() {
                let member: string =
                    "{output}_net_{net_labels[index]}.o"
                match fs.copy(net_objects[index], member) {
                    ok(_) => { io.println("built {member}") }
                    err(error) => {
                        self.fail(
                            member,
                            "cannot place networking bridge object: {error.msg}")
                        return false
                    }
                }
            }
            for index: int in 0..csrc_objects.len() {
                let member: string =
                    "{output}_csrc_{path.stem(self.csrc_sources[index])}.o"
                match fs.copy(csrc_objects[index], member) {
                    ok(_) => { io.println("built {member}") }
                    err(error) => {
                        self.fail(
                            member,
                            "cannot place csrc object: {error.msg}")
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
            if log_object != "" { archive.arg(log_object) }
            for net_object: string in net_objects {
                archive.arg(net_object)
            }
            for csrc_object: string in csrc_objects {
                archive.arg(csrc_object)
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
            if log_object != "" { wasm.arg(log_object) }
            for net_object: string in net_objects {
                wasm.arg(net_object)
            }
            for csrc_object: string in csrc_objects {
                wasm.arg(csrc_object)
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

        // The module's own chunks, compiled in parallel and cached by
        // content, before the link that reads them.
        var chunk_objects: List<string> = []
        if chunked {
            chunk_objects =
                self.cached_chunk_objects(
                    compiler, artifact_name, chunks)
            if chunk_objects.len() == 0 { return false }
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
        for flag: string in sanitizer_flags() {
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
        // PE linkers stamp the current time into the image header, so two
        // otherwise identical links differ. The fixed-point gate compares
        // stage binaries byte for byte and needs the reproducible spelling:
        // MSVC-style linkers replace the stamp with a content hash, GNU-style
        // ones write none.
        if self.target.object_format == "coff" {
            command.arg(
                if self.target.env == "msvc" {
                    "-Wl,/Brepro"
                } else {
                    "-Wl,--no-insert-timestamp"
                })
        }
        if chunked {
            // chunk order, not completion order: the link line is what
            // decides the layout of the binary
            for chunk_object: string in chunk_objects {
                command.arg(chunk_object)
            }
        } else {
            command.arg(ir_path)
        }
        if ffi_path != "" {
            if self.log_enabled {
                command.arg("-x")
                command.arg("c")
            }
            command.arg(ffi_path)
            if self.log_enabled {
                command.arg("-x")
                command.arg("none")
            }
        }
        command.arg(runtime_object)
        for encoding_object: string in encoding_objects {
            command.arg(encoding_object)
        }
        if log_object != "" { command.arg(log_object) }
        for net_object: string in net_objects {
            command.arg(net_object)
        }
        for csrc_object: string in csrc_objects {
            command.arg(csrc_object)
        }
        for argument: string in self.link_arguments {
            command.arg(argument)
        }
        // Networking bridges that stand on platform libraries (TLS, hash)
        // bring their own link arguments, after the objects that use them.
        for argument: string in
            net_bridge_link_arguments(
                self.net_features, self.target.os) {
            command.arg(argument)
        }
        for argument: string in
            log_bridge_link_arguments(
                self.log_enabled, self.target.os,
                self.target.env) {
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
