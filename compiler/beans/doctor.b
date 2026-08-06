// `beansc doctor` — what this installation can do, and the exact command to fix
// whatever it cannot.
//
// The point is that a user never has to read a Clang or linker error to find out
// that a toolchain is missing. Every row either says `ready` or names the one
// thing to install, so the answer to "why did my build fail" is one command away.
// Nothing here is allowed to fail: a missing optional tool is a report line, not
// an error.

import std.fs
import std.io
import std.os
import std.path
import std.process

fn doctor_env(name: string) -> string {
    match os.env(name) {
        some(value) => { return value }
        none => {}
    }
    return ""
}

fn doctor_windows_host() -> bool {
    return host_target_name().contains("windows")
}

fn doctor_macos_host() -> bool {
    return host_target_name().contains("darwin")
}

fn doctor_path_separator() -> string {
    return if doctor_windows_host() { ";" } else { ":" }
}

// Resolve a program the way the build driver will: an explicit path is taken as
// written, a bare name is looked up on PATH. Returns "" when nothing matches, so
// the report can say `not found` instead of printing a name that does not run.
fn doctor_resolve(program: string) -> string {
    if program == "" { return "" }
    if program.contains("/") || program.contains("\\") {
        if File.exists(program) { return program }
        if doctor_windows_host() &&
           File.exists("{program}.exe") {
            return "{program}.exe"
        }
        return ""
    }
    let search: string = doctor_env("PATH")
    for entry: string in search.split(doctor_path_separator()) {
        if entry == "" { continue }
        let candidate: string = path.join(entry, program)
        if File.exists(candidate) { return candidate }
        if doctor_windows_host() &&
           File.exists("{candidate}.exe") {
            return "{candidate}.exe"
        }
    }
    return ""
}

// First line of `<program> <flag>`, or "" when the tool could not be started or
// refused the flag. Presence is decided by doctor_resolve, not by this: a tool
// whose version cannot be read is still reported, just without a version.
fn doctor_tool_line(program: string, flag: string) -> string {
    if program == "" { return "" }
    let command: process.Command =
        new process.Command(program)
    command.arg(flag)
    match command.run() {
        ok(done) => {
            if !done.ok() { return "" }
            for line: string in done.text().lines() {
                let trimmed: string = line.trim()
                if trimmed != "" { return trimmed }
            }
        }
        err(_) => {}
    }
    return ""
}

fn doctor_install_root() -> string {
    let home: string = doctor_env("BEANS_HOME")
    if home != "" { return home }
    return beans_home()
}

// The VERSION file is written by the packaging scripts, so a real installation
// can state its own class rather than have the compiler guess. A checkout has no
// VERSION file; that case reports itself as a source tree.
fn doctor_version_field(root: string, key: string) -> string {
    var text: string = ""
    match fs.read(path.join(root, "VERSION")) {
        ok(contents) => { text = contents }
        err(_) => { return "" }
    }
    let prefix: string = "{key}="
    for line: string in text.lines() {
        let trimmed: string = line.trim()
        if trimmed.starts_with(prefix) {
            return trimmed.slice(
                prefix.len(), trimmed.len())
        }
    }
    return ""
}

fn doctor_bundled_clang(root: string) -> string {
    let unix: string =
        path.join(root, "toolchain/bin/clang")
    if File.exists(unix) { return unix }
    let windows: string =
        path.join(root, "toolchain/bin/clang.exe")
    if File.exists(windows) { return windows }
    return ""
}

fn doctor_bundled_tool(root: string, name: string) -> string {
    let plain: string =
        path.join(root, "toolchain/bin/{name}")
    if File.exists(plain) { return plain }
    let windows: string =
        path.join(root, "toolchain/bin/{name}.exe")
    if File.exists(windows) { return windows }
    return ""
}

fn doctor_row(label: string, value: string) -> string {
    let width: int = 20
    var padded: string = label
    if label.len() < width {
        let space: string = " "
        let gap: string =
            space.repeat(width - label.len())
        padded = "{label}{gap}"
    }
    return "{padded}{value}"
}

class DoctorReport {
    fixes: List<string>

    fn init() {
        self.fixes = []
    }

    fn note_fix(fix: string) {
        for existing: string in self.fixes {
            if existing == fix { return }
        }
        self.fixes.push(fix)
    }

    fn capability(label: string, ready: bool,
                  fix: string) -> string {
        if ready {
            return doctor_row("{label}:", "ready")
        }
        self.note_fix(fix)
        return doctor_row("{label}:", "not ready — {fix}")
    }
}

fn run_doctor() -> int {
    let report: DoctorReport = new DoctorReport()
    let root: string = doctor_install_root()
    let declared_class: string =
        doctor_version_field(root, "package")
    let bundled_clang: string = doctor_bundled_clang(root)
    var package_class: string = declared_class
    if package_class == "" {
        package_class = "source tree"
        if bundled_clang != "" {
            package_class = "full (undeclared)"
        }
    }

    let stdlib: string = stdlib_root()
    let stdlib_ok: bool = Dir.exists(stdlib)
    let runtime: string =
        if doctor_env("BEANS_RUNTIME") != "" {
            doctor_env("BEANS_RUNTIME")
        } else {
            "runtime/beans_rt.c"
        }
    let runtime_ok: bool = File.exists(runtime)
    let wasm_host: string =
        if doctor_env("BEANS_WASM_HOST") != "" {
            doctor_env("BEANS_WASM_HOST")
        } else {
            "runtime/wasm_host.c"
        }

    let requested_cc: string =
        if doctor_env("BEANS_CC") != "" {
            doctor_env("BEANS_CC")
        } else {
            "clang"
        }
    let clang: string = doctor_resolve(requested_cc)
    let clang_version: string =
        doctor_tool_line(clang, "--version")

    let requested_ar: string =
        if doctor_env("BEANS_AR") != "" {
            doctor_env("BEANS_AR")
        } else {
            "ar"
        }
    let archiver: string = doctor_resolve(requested_ar)

    let bundled_lld: string =
        doctor_bundled_tool(root, "ld.lld")
    let system_lld: string = doctor_resolve("ld.lld")
    var linker: string = "the C driver's default linker"
    if bundled_lld != "" {
        linker = "{bundled_lld} (bundled lld)"
    } else if system_lld != "" {
        linker = "{system_lld} (lld)"
    }

    let git: string = doctor_resolve("git")

    // macOS is the one host where the SDK cannot be bundled: it belongs to
    // Apple. Ask xcode-select rather than guessing from a path, and hand back
    // the exact install command when it says no.
    var sysroot: string = ""
    var macos_sdk_ready: bool = true
    let bundled_sysroot: string =
        path.join(root, "toolchain/sysroot")
    if Dir.exists(bundled_sysroot) {
        sysroot = "{bundled_sysroot} (bundled)"
    } else if doctor_macos_host() {
        let selected: string =
            doctor_tool_line("xcode-select", "-p")
        if selected == "" || !Dir.exists(selected) {
            sysroot = "missing — Command Line Tools are not installed"
            macos_sdk_ready = false
        } else {
            sysroot = "{selected} (Command Line Tools)"
        }
    } else {
        sysroot = "the C driver's default"
    }

    io.println(compiler_banner())
    io.println("")
    io.println(doctor_row("package:", package_class))
    io.println(
        doctor_row("host target:", host_target_name()))
    io.println(doctor_row("install root:", root))
    let missing_note: string = " (missing)"
    var stdlib_shown: string = stdlib
    if !stdlib_ok { stdlib_shown = "{stdlib}{missing_note}" }
    var runtime_shown: string = runtime
    if !runtime_ok { runtime_shown = "{runtime}{missing_note}" }
    var wasm_shown: string = wasm_host
    if !File.exists(wasm_host) {
        wasm_shown = "{wasm_host}{missing_note}"
    }
    io.println(
        doctor_row("standard library:", stdlib_shown))
    io.println(
        doctor_row("runtime source:", runtime_shown))
    io.println(
        doctor_row("wasm host source:", wasm_shown))
    var clang_shown: string =
        "not found (looked for '{requested_cc}')"
    if clang != "" {
        clang_shown = clang
        if clang_version != "" {
            clang_shown = "{clang} - {clang_version}"
        }
    }
    var archiver_shown: string =
        "not found (looked for '{requested_ar}')"
    if archiver != "" { archiver_shown = archiver }
    var git_shown: string =
        "not found (only needed for git package dependencies)"
    if git != "" { git_shown = git }
    io.println(doctor_row("clang:", clang_shown))
    io.println(doctor_row("linker:", linker))
    io.println(doctor_row("archiver:", archiver_shown))
    io.println(doctor_row("sdk / sysroot:", sysroot))
    io.println(doctor_row("git:", git_shown))
    io.println("")

    let clang_fix: string =
        if doctor_macos_host() {
            "run: xcode-select --install"
        } else if doctor_windows_host() {
            "install Clang, or reinstall the full Beans package that bundles it"
        } else {
            "install clang (Debian/Ubuntu: sudo apt-get install clang lld), or reinstall the full Beans package that bundles it"
        }
    let sdk_fix: string = "run: xcode-select --install"
    let stdlib_fix: string =
        "point BEANS_STDLIB at the package's lib/std directory"
    let runtime_fix: string =
        "point BEANS_RUNTIME at the package's bin/beans_rt.c"
    let archiver_fix: string =
        "install llvm-ar or ar, or set BEANS_AR"

    let frontend_ready: bool = stdlib_ok
    let clang_ready: bool = clang != ""
    let native_ready: bool =
        frontend_ready && runtime_ok && clang_ready &&
        macos_sdk_ready

    io.println(
        report.capability("check", frontend_ready, stdlib_fix))
    io.println(
        report.capability("run", frontend_ready, stdlib_fix))
    io.println(
        report.capability("llvm", frontend_ready, stdlib_fix))
    io.println(
        report.capability(
            "build --emit ir", frontend_ready, stdlib_fix))
    io.println(
        report.capability(
            "native build",
            native_ready,
            if !frontend_ready {
                stdlib_fix
            } else if !runtime_ok {
                runtime_fix
            } else if !clang_ready {
                clang_fix
            } else {
                sdk_fix
            }))
    io.println(
        report.capability(
            "bindgen", clang_ready, clang_fix))
    io.println(
        report.capability(
            "static library",
            native_ready && archiver != "",
            if !native_ready {
                if !clang_ready { clang_fix } else { sdk_fix }
            } else {
                archiver_fix
            }))

    if report.fixes.len() != 0 {
        io.println("")
        io.println("to fix:")
        for fix: string in report.fixes {
            io.println("  {fix}")
        }
    }
    // A report is not a failure. `doctor` exits 0 whenever it could produce one,
    // so a script can run it for information without having to ignore a status.
    return 0
}
