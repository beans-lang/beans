package main

import std.fs
import std.os
import std.path
import std.process
import std.random
import std.time

// ---- canonical identity -----------------------------------------------
//
// A declaration's identity is its package's import path plus its declared
// name, joined by "::". Neither an identifier nor an import path can hold a
// colon, so the split is unambiguous and no phase has to guess where the
// package ends. Builtins keep bare names, so they live in their own
// namespace with no "::" at all.
fn package_symbol(package_id: string, name: string) -> string {
    return "{package_id}::{name}"
}

// "" for a bare builtin name.
fn symbol_package(key: string) -> string {
    match key.find("::") {
        some(cut) => { return key.slice(0, cut) }
        none => { return "" }
    }
}

fn symbol_name(key: string) -> string {
    match key.find("::") {
        some(cut) => { return key.slice(cut + 2, key.len()) }
        none => { return key }
    }
}

// A canonical name written for a person: the import path and the declared
// name, joined the way source would spell them. Diagnostics use this so the
// internal "::" never reaches a message.
fn display_symbol(key: string) -> string {
    let package_id: string = symbol_package(key)
    if package_id == "" { return key }
    return "{package_id}.{symbol_name(key)}"
}

// One piece of a symbol name. A package path can carry '/' and '-', neither
// of which is legal in a linker symbol or an LLVM identifier, so each is
// escaped through '$'.
fn symbol_escape(text: string) -> string {
    var out: string = ""
    for index: int in 0..text.len() {
        let byte: int = text.byte_at(index)
        let plain: bool =
            (byte >= 97 && byte <= 122) ||
            (byte >= 65 && byte <= 90) ||
            (byte >= 48 && byte <= 57) ||
            byte == 95 || byte == 46
        if plain {
            out = "{out}{text.slice(index, index + 1)}"
        } else if byte == 36 {
            out = "{out}$$"
        } else if byte == 47 {
            out = "{out}$s"
        } else if byte == 45 {
            out = "{out}$d"
        } else {
            // Unreachable for validated paths and identifiers; kept so no
            // future path spelling can silently produce a bad symbol.
            out = "{out}$u{byte}."
        }
    }
    return out
}

// The "::" becomes a single '$', and the package path keeps its dots, so
// "shop.money::Money" reads as "shop.money$Money". An identifier never
// contains '$', so the last '$' is always the separator and the mapping stays
// injective.
fn symbol_text(key: string) -> string {
    match key.find("::") {
        some(cut) => {
            let package_id: string = key.slice(0, cut)
            let name: string = key.slice(cut + 2, key.len())
            return "{symbol_escape(package_id)}${symbol_escape(name)}"
        }
        none => { return symbol_escape(key) }
    }
}

// The compiler-owned async runtime. '$' keeps the path unspellable by an
// import, so the compiler is its only importer and names it directly.
fn async_rt_package() -> string {
    return "std.async$rt"
}

fn async_rt_symbol(name: string) -> string {
    return package_symbol(async_rt_package(), name)
}

fn ast_needs_async_runtime(node: AstNode) -> bool {
    if node.kind == "fn" && value_marks_async(node.value) {
        return true
    }
    if node.kind == "closure" && node.note == "async" {
        return true
    }
    if node.kind == "fn_type" &&
       module_words(node.value).contains("async") {
        return true
    }
    for child: AstNode in node.children {
        if ast_needs_async_runtime(child) { return true }
    }
    return false
}

// One name selected in `import {…} from path`: the symbol `name` of the
// import's target, bound in its own file as `binding` — the `as` alias
// when one was written, the name itself otherwise.
class NamedImport {
    name: string
    alias: string
    binding: string
    node: AstNode
    line: int
    col: int

    fn init(name: string, alias: string, node: AstNode) {
        self.name = name
        self.alias = alias
        self.binding = ""
        self.node = node
        self.line = node.line
        self.col = node.col
    }
}

// One import written in one file. The source spelling is kept apart from the
// canonical target: a local import inside a git checkout resolves onto the
// path its dependents use, and diagnostics still show what was written.
// A selective import carries its selection in `names` and binds no module
// name at all: `binding` stays "".
class ModuleImport {
    path: string      // verbatim source spelling
    alias: string     // `as` name, "" if none
    resolved: string  // canonical Package ID, "" for a native std namespace
    binding: string   // the name this import binds in its own file
    names: List<NamedImport>
    node: AstNode
    line: int
    col: int

    fn init(path: string, alias: string, node: AstNode) {
        self.path = path
        self.alias = alias
        self.resolved = ""
        self.binding = ""
        self.names = []
        self.node = node
        self.line = node.line
        self.col = node.col
    }
}

class ParsedModuleFile {
    source_id: int
    path: string
    ast: AstNode
    // The package clause, or "" when the file has none.
    package_name: string
    package_line: int
    package_col: int
    imports: List<ModuleImport>

    fn init(source_id: int, path: string, ast: AstNode) {
        self.source_id = source_id
        self.path = path
        self.ast = ast
        self.package_name = ""
        self.package_line = 0
        self.package_col = 0
        self.imports = []
    }
}

// One import edge of the package graph, kept with the exact source spot that
// wrote it so a cycle can be printed in full.
struct ImportEdge {
    from: string
    to: string
    file: string
    line: int
}

struct LockEntry {
    path: string
    requested: string
    commit: string
    tree: string
}

struct ModuleLink {
    selector: string
    kind: string
    value: string
    root: string
}

// One package = one directory of .b files sharing a namespace.
//
// `import_path` is the package's identity: the canonical path every importer
// resolves to. `name` is only source-facing — the declared `package` clause,
// used as the default import binding and in diagnostics. Two packages may
// share a name; they can never share an import_path.
class LoadedPackage {
    import_path: string
    name: string
    dir: string
    files: List<ParsedModuleFile>
    imports: List<string>

    fn init(import_path: string, dir: string) {
        self.import_path = import_path
        self.name = ""
        self.dir = dir
        self.files = []
        self.imports = []
    }
}

// A legal package name is a lowercase snake_case identifier: the same rule
// the language already documents for package directories.
fn legal_package_name(name: string) -> bool {
    if name == "" { return false }
    let first: int = name.byte_at(0)
    if !(first >= 97 && first <= 122) { return false }
    if name.byte_at(name.len() - 1) == 95 { return false }
    var previous_underscore: bool = false
    for index: int in 0..name.len() {
        let byte: int = name.byte_at(index)
        let lower: bool = byte >= 97 && byte <= 122
        let digit: bool = byte >= 48 && byte <= 57
        if !lower && !digit && byte != 95 { return false }
        if byte == 95 && previous_underscore { return false }
        previous_underscore = byte == 95
    }
    return true
}

fn module_words(line: string) -> List<string> {
    let raw: List<string> = line.trim().split(" ")
    var words: List<string> = []
    for word: string in raw {
        if word != "" { words.push(word) }
    }
    return move words
}

// Tokenize beans.pot without losing quoted paths. Comments only start outside
// quotes, so link values and local directories may contain either marker.
fn manifest_words(line: string) -> List<string> {
    var words: List<string> = []
    var word: string = ""
    var started: bool = false
    var quoted: bool = false
    var escaping: bool = false
    var index: int = 0
    for index < line.len() {
        let byte: int = line.byte_at(index)
        if quoted {
            if escaping {
                word = "{word}{line.slice(index, index + 1)}"
                escaping = false
            } else if byte == 92 {
                escaping = true
            } else if byte == 34 {
                quoted = false
            } else {
                word = "{word}{line.slice(index, index + 1)}"
            }
            index += 1
            continue
        }
        if byte == 34 {
            quoted = true
            started = true
            index += 1
            continue
        }
        let slash_comment: bool =
            byte == 47 && index + 1 < line.len() &&
            line.byte_at(index + 1) == 47
        if byte == 35 || slash_comment {
            break
        }
        if byte == 32 || byte == 9 || byte == 13 {
            if started {
                words.push(word)
                word = ""
                started = false
            }
        } else {
            word = "{word}{line.slice(index, index + 1)}"
            started = true
        }
        index += 1
    }
    if started { words.push(word) }
    if quoted || escaping {
        words = ["$manifest-error:unterminated-quote$"]
    }
    return move words
}

fn normalize_local_path(value: string) -> string {
    let absolute: bool = value.starts_with("/")
    let raw: List<string> = value.replace("\\", "/").split("/")
    var parts: List<string> = []
    for part: string in raw {
        if part == "" || part == "." { continue }
        if part == ".." && parts.len() != 0 &&
           parts[parts.len() - 1] != ".." {
            parts.pop()
        } else if part == ".." && !absolute {
            parts.push(part)
        } else if part != ".." {
            parts.push(part)
        }
    }
    var result: string = if absolute { "/" } else { "" }
    for part: string in parts {
        if result != "" && !result.ends_with("/") { result = "{result}/" }
        result = "{result}{part}"
    }
    if result == "" { return if absolute { "/" } else { "." } }
    return result
}

fn absolute_local_path(value: string) -> string {
    let normalized: string = normalize_local_path(value)
    let windows_absolute: bool =
        normalized.len() >= 3 && normalized.byte_at(1) == 58 &&
        normalized.byte_at(2) == 47
    if normalized.starts_with("/") || windows_absolute {
        return normalized
    }
    return normalize_local_path(path.join(Dir.current(), normalized))
}

fn local_module_key(root: string, name: string) -> string {
    return "{root}\n{name}"
}

// The final segment of an import path. Only a native std namespace with no
// source package uses this as its name; every loaded package declares one.
fn last_path_segment(import_path: string) -> string {
    let parts: List<string> = import_path.replace("/", ".").split(".")
    return parts[parts.len() - 1]
}

// These namespaces are implemented by the compiler/runtime and therefore
// have no source directory under stdlib/std. Every other std.* path must
// resolve to a real package.
fn native_std_namespace(import_path: string) -> bool {
    return import_path == "std.asm" ||
           import_path == "std.c" ||
           import_path == "std.cpu" ||
           import_path == "std.dl" ||
           import_path == "std.intrinsic" ||
           import_path == "std.io" ||
           import_path == "std.os" ||
           import_path == "std.proc" ||
           import_path == "std.random" ||
           import_path == "std.ready" ||
           import_path == "std.reflection" ||
           import_path == "std.sig" ||
           import_path == "std.sock" ||
           import_path == "std.target" ||
           import_path == "std.thread" ||
           import_path == "std.time"
}

fn safe_git_id(value: string) -> bool {
    if value.len() < 7 || value.len() > 128 { return false }
    for index: int in 0..value.len() {
        let byte: int = value.byte_at(index)
        if !((byte >= 48 && byte <= 57) ||
             (byte >= 65 && byte <= 70) ||
             (byte >= 97 && byte <= 102)) {
            return false
        }
    }
    return true
}

fn safe_remote_path(value: string) -> bool {
    if value == "" || value.starts_with("/") || value.contains("..") {
        return false
    }
    let segments: List<string> = value.split("/")
    if segments.len() != 3 { return false }
    for segment: string in segments {
        if segment == "" { return false }
        for index: int in 0..segment.len() {
            let byte: int = segment.byte_at(index)
            if !((byte >= 48 && byte <= 57) ||
                 (byte >= 65 && byte <= 90) ||
                 (byte >= 97 && byte <= 122) ||
                 byte == 45 || byte == 46 || byte == 95) {
                return false
            }
        }
    }
    return true
}

fn beans_home() -> string {
    match os.env("BEANS_HOME") {
        some(home) => { return home }
        none => {}
    }
    match os.env("HOME") {
        some(home) => { return path.join(home, ".beans") }
        none => {}
    }
    // Windows spells the home directory USERPROFILE; a POSIX host without
    // HOME set falls through to the same relative default either way.
    match os.env("USERPROFILE") {
        some(home) => { return path.join(home, ".beans") }
        none => { return ".beans" }
    }
}

fn stdlib_root() -> string {
    match os.env("BEANS_STDLIB") {
        some(root) => { return root }
        none => {}
    }
    if Dir.exists("stdlib/std") { return "stdlib/std" }
    return path.join(beans_home(), "lib/std")
}

// The standard-library tree containing a source file. The configured install
// wins, while the ancestor check also recognizes a compiler checkout opened
// by an editor whose process did not start in that checkout.
fn stdlib_source_root(file_path: string) -> string {
    let file: string = absolute_local_path(file_path)
    let configured: string = absolute_local_path(stdlib_root())
    if file.starts_with("{configured}/") { return configured }
    var directory: string = path.parent(file)
    for directory != "" {
        let parent: string = path.parent(directory)
        if path.name(directory) == "std" &&
           path.name(parent) == "stdlib" {
            return directory
        }
        if parent == "" || parent == directory { break }
        directory = parent
    }
    return ""
}

// A source file below a standard-library root is already part of a package
// even though stdlib deliberately has no beans.pot. Recover the same canonical
// package path an `import std.*` would use instead of making it a loose main.
fn stdlib_source_package(file_path: string) -> string {
    let file: string = absolute_local_path(file_path)
    let root: string = stdlib_source_root(file_path)
    if root == "" || !file.ends_with(".b") { return "" }
    let relative: string =
        file.slice(root.len() + 1, file.len())
    let directory: string = path.parent(relative)
    if directory == "" || directory == "." { return "" }
    return "std.{directory.replace("/", ".")}"
}

fn manifest_link_arguments(links: List<ModuleLink>,
                           target: TargetDescription) -> List<string> {
    var arguments: List<string> = []
    for link: ModuleLink in links {
        if link.selector != "all" &&
           link.selector != target.os &&
           link.selector != target.triple {
            continue
        }
        if link.kind == "search" {
            arguments.push(
                "-L{path.join(link.root, link.value)}")
        } else if link.kind == "library" {
            arguments.push("-l{link.value}")
        } else {
            arguments.push("-framework")
            arguments.push(link.value)
        }
    }
    return move arguments
}

class ModuleLoader {
    sources: SourceManager
    module_name: string
    entry_package: string
    kind: string
    root: string
    packages: List<LoadedPackage>
    errors: List<Diagnostic>
    state: Map<string, int>
    package_names: Map<string, string>
    requirements: Map<string, string>
    lock_entries: Map<string, LockEntry>
    resolved_entries: Map<string, LockEntry>
    locked: bool
    offline: bool
    lock_mode: string
    update_module: string
    clone_number: int
    remote_names: Map<string, string>
    local_modules: Map<string, string>
    local_names: Map<string, string>
    local_name_roots: Map<string, string>
    links: List<ModuleLink>
    csrc_rows: List<ModuleLink>
    overlays: Map<string, string>
    want_reactor: bool
    want_async_thread: bool
    has_local_dependencies: bool
    // The depth-first stack of packages being loaded, and the import edge
    // that pushed each one (stack_edges[i] led to stack[i]).
    stack: List<string>
    stack_edges: List<ImportEdge>

    fn init(sources: SourceManager, locked: bool, offline: bool,
            lock_mode: string, update_module: string) {
        self.sources = sources
        self.module_name = ""
        self.entry_package = ""
        self.kind = "application"
        self.root = ""
        self.packages = []
        self.errors = []
        self.state = {}
        self.package_names = {}
        self.requirements = {}
        self.lock_entries = {}
        self.resolved_entries = {}
        self.locked = locked
        self.offline = offline
        self.lock_mode = lock_mode
        self.update_module = update_module
        self.clone_number = 0
        self.remote_names = {}
        self.local_modules = {}
        self.local_names = {}
        self.local_name_roots = {}
        self.links = []
        self.csrc_rows = []
        self.overlays = {}
        self.want_reactor = false
        self.want_async_thread = false
        self.has_local_dependencies = false
        self.stack = []
        self.stack_edges = []
    }

    fn set_overlay(file_path: string, text: string) {
        self.overlays[file_path] = text
    }

    fn fail(path: string, line: int, col: int, message: string) {
        self.errors.push(Diagnostic {
            severity: Severity.error,
            file: path,
            line: line,
            col: col,
            message: message,
        })
    }

    fn find_root(entry: string) -> string {
        var dir: string = path.parent(entry)
        if dir == "" { dir = "." }
        for true {
            if File.exists(path.join(dir, "beans.pot")) { return dir }
            let parent: string = path.parent(dir)
            if parent == "" || parent == dir { break }
            dir = parent
        }

        // A bare relative entry from a nested working directory starts at
        // `.`. Pure path.parent cannot walk above that spelling, so retry from
        // the real absolute directory. This is the same lookup stage 0 does
        // with std::filesystem::absolute.
        dir = path.parent(absolute_local_path(entry))
        for true {
            if File.exists(path.join(dir, "beans.pot")) { return dir }
            let parent: string = path.parent(dir)
            if parent == "" || parent == dir { return "" }
            dir = parent
        }
        return ""
    }

    fn read_manifest_declared_name(root: string, from_path: string,
                                   from_line: int) -> string {
        let mod_path: string = path.join(root, "beans.pot")
        if !File.exists(mod_path) {
            self.fail(from_path, from_line, 1,
                      "no beans.pot in {root}")
            return ""
        }
        let text: string = fs.read(mod_path).expect("read beans.pot")
        var name: string = ""
        var line_number: int = 0
        for line: string in text.lines() {
            line_number += 1
            let words: List<string> = manifest_words(line)
            if words.len() == 1 &&
               words[0] == "$manifest-error:unterminated-quote$" {
                self.fail(mod_path, line_number, 1,
                          "unterminated quoted string")
                continue
            }
            if words.len() == 0 || words[0] != "module" { continue }
            if words.len() != 2 {
                self.fail(mod_path, line_number, 1,
                          "module needs exactly 'module <name>'")
            } else if name != "" {
                self.fail(mod_path, line_number, 1,
                          "beans.pot has more than one module line")
            } else {
                name = words[1]
            }
        }
        if name == "" {
            self.fail(mod_path, 0, 0,
                      "beans.pot needs a 'module <name>' line")
        }
        return name
    }

    fn read_module_name(root: string) -> string {
        let mod_path: string = path.join(root, "beans.pot")
        let text: string = fs.read(mod_path).expect("read beans.pot")
        var name: string = ""
        var manifest_kind: string = "application"
        var saw_kind: bool = false
        var line_number: int = 0
        for line: string in text.lines() {
            line_number += 1
            let words: List<string> = manifest_words(line)
            if words.len() == 1 &&
               words[0] == "$manifest-error:unterminated-quote$" {
                self.fail(mod_path, line_number, 1,
                          "unterminated quoted string")
                continue
            }
            if words.len() == 0 { continue }
            if words[0] == "module" && words.len() == 2 {
                if name != "" {
                    self.fail(mod_path, 0, 0,
                              "beans.pot has more than one module line")
                }
                name = words[1]
            } else if words[0] == "kind" {
                if saw_kind {
                    self.fail(mod_path, 0, 0,
                              "beans.pot has more than one kind line")
                } else if words.len() != 2 ||
                          (words[1] != "application" &&
                           words[1] != "library") {
                    self.fail(
                        mod_path, 0, 0,
                        "kind needs exactly 'kind application' or 'kind library'")
                } else {
                    manifest_kind = words[1]
                }
                saw_kind = true
            } else if words[0] == "require" {
                if words.len() != 3 {
                    self.fail(
                        mod_path, line_number, 1,
                        "require needs 'require <git-path> <tag>' or 'require path \"<directory>\"'")
                } else if words[1] == "path" {
                    self.has_local_dependencies = true
                    let target_root: string = normalize_local_path(
                        path.join(root, words[2]))
                    if !Dir.exists(target_root) {
                        self.fail(
                            mod_path, line_number, 1,
                            "local dependency directory does not exist: {words[2]}")
                        continue
                    }
                    let target_name: string =
                        self.read_manifest_declared_name(
                            target_root, mod_path, line_number)
                    if target_name == "" { continue }
                    let previous_root: string =
                        self.local_name_roots.get(target_name).or("")
                    if target_root == root || target_name == name {
                        self.fail(
                            mod_path, line_number, 1,
                            "local dependency cannot refer to its own module")
                    } else if previous_root != "" &&
                              previous_root != target_root {
                        self.fail(
                            mod_path, line_number, 1,
                            "local module '{target_name}' refers to both {previous_root} and {target_root}")
                    } else {
                        let key: string =
                            local_module_key(root, target_name)
                        let previous: string =
                            self.local_modules.get(key).or("")
                        if previous != "" && previous != target_root {
                            self.fail(
                                mod_path, line_number, 1,
                                "local module '{target_name}' is required from two directories")
                        } else {
                            self.local_modules[key] = target_root
                            self.local_name_roots[target_name] = target_root
                        }
                    }
                } else {
                    let required_path: string = words[1]
                    let requested: string = words[2]
                    let previous: string =
                        self.requirements.get(required_path).or("")
                    if previous != "" && previous != requested {
                        self.fail(mod_path, line_number, 1,
                                  "dependency {required_path} is required at both {previous} and {requested}")
                    } else {
                        self.requirements[required_path] = requested
                    }
                }
            } else if words[0] == "link" && words.len() == 4 {
                let selector: string = words[1]
                let kind: string = words[2]
                if kind != "search" && kind != "library" &&
                   kind != "framework" {
                    self.fail(
                        mod_path, 0, 0,
                        "link kind must be search, library, or framework")
                } else {
                    self.links.push(ModuleLink {
                        selector: selector,
                        kind: kind,
                        value: words[3],
                        root: root,
                    })
                }
            } else if words[0] == "csrc" {
                // csrc <selector> "<file.c>" — a C source this package
                // owns; the toolchain compiles it, so the package ships
                // no prebuilt binaries and pushes no build step onto
                // consumers. Rows propagate exactly like link rows.
                if words.len() != 3 {
                    self.fail(
                        mod_path, line_number, 1,
                        "csrc needs 'csrc <selector> \"<file.c>\"'")
                } else if !File.exists(
                              path.join(root, words[2])) {
                    self.fail(
                        mod_path, line_number, 1,
                        "csrc file does not exist: {words[2]}")
                } else {
                    self.csrc_rows.push(ModuleLink {
                        selector: words[1],
                        kind: "csrc",
                        value: words[2],
                        root: root,
                    })
                }
            } else {
                self.fail(mod_path, 0, 0,
                          "unknown beans.pot line: {line}")
            }
        }
        if name == "" {
            self.fail(mod_path, 0, 0,
                      "beans.pot needs a module line")
        }
        if root == self.root {
            self.kind = manifest_kind
        }
        return name
    }

    fn link_arguments(target: TargetDescription) -> List<string> {
        return manifest_link_arguments(self.links, target)
    }

    fn read_lock(root: string) {
        let lock_path: string = path.join(root, "beans.lock")
        if !File.exists(lock_path) {
            if self.offline && !self.has_local_dependencies {
                self.fail(lock_path, 0, 0,
                          "offline dependency loading needs a committed beans.lock")
            } else if self.locked && !self.has_local_dependencies {
                self.fail(lock_path, 0, 0,
                          "--locked needs a committed beans.lock")
            }
            return
        }

        let text: string = fs.read(lock_path).expect("read beans.lock")
        var saw_version: bool = false
        var line_number: int = 0
        for line: string in text.lines() {
            line_number += 1
            let words: List<string> = module_words(line)
            if words.len() == 0 || words[0].starts_with("//") {
                continue
            }
            if words[0] == "version" {
                if words.len() != 2 || words[1] != "1" {
                    self.fail(lock_path, line_number, 1,
                              "beans.lock version must be exactly 'version 1'")
                } else if saw_version {
                    self.fail(lock_path, line_number, 1,
                              "beans.lock has more than one version line")
                }
                saw_version = true
                continue
            }
            if words[0] != "module" {
                self.fail(lock_path, line_number, 1,
                          "unknown beans.lock row '{words[0]}'")
                continue
            }
            if words.len() != 5 ||
               !safe_git_id(words[3]) || !safe_git_id(words[4]) {
                self.fail(lock_path, line_number, 1,
                          "module rows need path, requested ref, commit and tree hash")
                continue
            }
            if !safe_remote_path(words[1]) {
                self.fail(lock_path, line_number, 1,
                          "unsafe dependency path '{words[1]}'")
                continue
            }
            if self.lock_entries.contains_key(words[1]) {
                self.fail(lock_path, line_number, 1,
                          "dependency '{words[1]}' appears twice")
                continue
            }
            self.lock_entries[words[1]] = LockEntry {
                path: words[1],
                requested: words[2],
                commit: words[3],
                tree: words[4],
            }
        }
        if !saw_version {
            self.fail(lock_path, 0, 0,
                      "beans.lock needs a 'version 1' line")
        }
    }

    fn temporary_nonce() -> Option<int> {
        match random.u64() {
            ok(value) => { return some(value) }
            err(error) => {
                self.fail(self.root, 0, 0,
                          "cannot create a secure temporary name: {error.msg}")
                return none
            }
        }
    }

    fn write_lock() -> bool {
        var keys: List<string> = self.resolved_entries.keys()
        keys.sort()
        var contents: string = "version 1\n"
        for key: string in keys {
            let entry: LockEntry = self.resolved_entries[key]
            contents =
                "{contents}module {entry.path} {entry.requested} {entry.commit} {entry.tree}\n"
        }
        var nonce: int = 0
        match self.temporary_nonce() {
            some(value) => { nonce = value }
            none => { return false }
        }
        let lock_path: string = path.join(self.root, "beans.lock")
        let temporary: string =
            "{lock_path}.tmp-{time.monotonic_millis()}-{nonce}"
        if File.exists(temporary) {
            self.fail(temporary, 0, 0,
                      "stale temporary lockfile blocks the update")
            return false
        }
        match fs.write(temporary, contents) {
            ok(_) => {}
            err(error) => {
                File.remove(temporary)
                self.fail(lock_path, 0, 0,
                          "cannot create beans.lock: {error.msg}")
                return false
            }
        }
        match File.rename(temporary, lock_path) {
            ok(_) => { return true }
            err(error) => {
                File.remove(temporary)
                self.fail(lock_path, 0, 0,
                          "could not replace beans.lock: {error.msg}")
                return false
            }
        }
    }

    fn parse_file(file_path: string) -> ParsedModuleFile {
        var text: string = ""
        match self.overlays.get(file_path) {
            some(source) => { text = source }
            none => {
                match fs.read(file_path) {
                    ok(source) => { text = source }
                    err(error) => {
                        self.fail(
                            file_path, 0, 0,
                            "cannot read source: {error.msg}")
                    }
                }
            }
        }
        let source_id: int = self.sources.add(file_path, text)
        let lexer: Lexer = new Lexer(text)
        let tokens: List<Token> = lexer.scan()
        for diagnostic: Diagnostic in lexer.errors {
            self.fail(file_path, diagnostic.line, diagnostic.col,
                      diagnostic.message)
        }
        let parser: Parser = new Parser(move tokens)
        let ast: AstNode = parser.parse_module()
        for diagnostic: Diagnostic in parser.errors {
            self.fail(file_path, diagnostic.line, diagnostic.col,
                      diagnostic.message)
        }
        let parsed: ParsedModuleFile =
            new ParsedModuleFile(source_id, file_path, ast)
        for declaration: AstNode in ast.children {
            if declaration.kind == "package" &&
               parsed.package_name == "" {
                parsed.package_name = declaration.value
                parsed.package_line = declaration.line
                parsed.package_col = declaration.col
            }
            if declaration.kind != "import" { continue }
            var imported: string = declaration.value
            if imported.starts_with("pub ") {
                imported = imported.slice(4, imported.len())
            }
            var alias: string = ""
            for child: AstNode in declaration.children {
                if child.kind == "alias" { alias = child.value }
            }
            let entry: ModuleImport =
                new ModuleImport(imported, alias, declaration)
            for child: AstNode in declaration.children {
                if child.kind != "named" { continue }
                var named_alias: string = ""
                for grand: AstNode in child.children {
                    if grand.kind == "alias" {
                        named_alias = grand.value
                    }
                }
                entry.names.push(
                    new NamedImport(child.value, named_alias, child))
            }
            parsed.imports.push(entry)
        }
        return parsed
    }

    // Import positions read best relative to the module root; an absolute
    // build directory says nothing about the program.
    fn display_path(file: string) -> string {
        if self.root != "" && file.starts_with("{self.root}/") {
            return file.slice(self.root.len() + 1, file.len())
        }
        return file
    }

    // The import that closed a cycle knows only its own edge. The load stack
    // holds the rest, so the whole chain prints in the order the imports were
    // followed.
    fn report_cycle(target: string, from_file: string, line: int,
                    col: int) {
        var start: int = 0
        for start < self.stack.len() && self.stack[start] != target {
            start += 1
        }
        var message: string = "package import cycle:"
        for index: int in (start + 1)..self.stack.len() {
            let edge: ImportEdge = self.stack_edges[index]
            message =
                "{message}\n  {edge.from} imports {edge.to} at {self.display_path(edge.file)}:{edge.line}"
        }
        var closing_from: string = target
        if self.stack.len() != 0 {
            closing_from = self.stack[self.stack.len() - 1]
        }
        message =
            "{message}\n  {closing_from} imports {target} at {self.display_path(from_file)}:{line}"
        self.fail(from_file, line, col, message)
    }

    // Validates the `package` clauses of one directory and settles the
    // package's declared name. `role` is one of root_application,
    // root_library, imported or single_file.
    fn check_package_clause(package: LoadedPackage, role: string) {
        var named: Option<ParsedModuleFile> = none
        for file: ParsedModuleFile in package.files {
            if file.package_name == "" {
                if role == "single_file" { continue }
                self.fail(
                    file.path, 1, 1,
                    "this file has no package clause — every file in a package starts with 'package <name>'")
                continue
            }
            match named {
                none => {
                    named = some(file)
                    package.name = file.package_name
                    if !legal_package_name(package.name) {
                        self.fail(
                            file.path, file.package_line,
                            file.package_col,
                            "package name '{package.name}' is not a lowercase snake_case name")
                    }
                }
                some(first) => {
                    if file.package_name != first.package_name {
                        self.fail(
                            file.path, file.package_line,
                            file.package_col,
                            "this file declares package '{file.package_name}' but {self.display_path(first.path)} declares package '{first.package_name}' — one directory is one package")
                    }
                }
            }
        }

        if package.name == "" {
            // Keep going with a usable name so later phases still report real
            // problems rather than cascading on an empty qualifier.
            if role == "single_file" {
                package.name = "main"
            } else {
                package.name = last_path_segment(package.import_path)
            }
        }

        var where: Option<ParsedModuleFile> = named
        var line: int = 1
        var col: int = 1
        match named {
            some(file) => {
                line = file.package_line
                col = file.package_col
            }
            none => {
                if package.files.len() != 0 {
                    where = some(package.files[0])
                }
            }
        }
        var anchor: ParsedModuleFile = new ParsedModuleFile(
            0, "", new AstNode("module", "", 0, 0))
        match where {
            some(file) => { anchor = file }
            none => { return }
        }
        if role == "root_application" && package.name != "main" {
            self.fail(
                anchor.path, line, col,
                "the root of an application declares 'package main', not '{package.name}'")
        } else if role == "root_library" && package.name == "main" {
            self.fail(
                anchor.path, line, col,
                "a library root declares a normal package name, not 'main'")
        } else if role == "imported" && package.name == "main" {
            self.fail(
                anchor.path, line, col,
                "package '{package.import_path}' is imported, so it cannot declare 'package main'")
        } else if role == "single_file" && named.is_some() &&
                  package.name != "main" {
            self.fail(
                anchor.path, line, col,
                "a single file without a beans.pot declares 'package main' or no package clause at all")
        }
    }

    // Import bindings are per file, so they are settled once every package's
    // declared name is known — an import's default name is what its target
    // declares, not the last segment of the path that reached it.
    fn bind_imports() {
        for package: LoadedPackage in self.packages {
            for file: ParsedModuleFile in package.files {
                var bound: Map<string, string> = {}
                for imported: ModuleImport in file.imports {
                    if imported.names.len() != 0 {
                        // A selective import binds only its selection,
                        // never a module name.
                        for named: NamedImport in imported.names {
                            named.binding =
                                if named.alias != "" {
                                    named.alias
                                } else {
                                    named.name
                                }
                            let previous: string =
                                bound.get(named.binding).or("")
                            if previous != "" {
                                self.fail(
                                    file.path, named.line, named.col,
                                    "import name '{named.binding}' is already taken in this file by '{previous}' — give one of them a different name with 'as'")
                            } else {
                                bound[named.binding] =
                                    "{imported.path}.{named.name}"
                            }
                        }
                        continue
                    }
                    if imported.alias != "" {
                        imported.binding = imported.alias
                    } else {
                        var target: string = imported.resolved
                        if target == "" { target = imported.path }
                        // A std path with no source package is a native
                        // namespace; it declares nothing, so its last
                        // segment names it.
                        let fallback: string =
                            last_path_segment(imported.path)
                        imported.binding =
                            self.package_names.get(target).or(fallback)
                    }
                    let previous: string =
                        bound.get(imported.binding).or("")
                    if previous != "" {
                        self.fail(
                            file.path, imported.line, imported.col,
                            "import name '{imported.binding}' is already taken in this file by '{previous}' — give one of them a different name with 'as'")
                    } else {
                        bound[imported.binding] = imported.path
                    }
                }
            }
        }
    }

    fn local_import_dir(import_path: string, context_name: string,
                        context_root: string) -> string {
        if import_path == context_name { return context_root }
        let prefix: string = "{context_name}."
        if !import_path.starts_with(prefix) { return "" }
        var relative: string =
            import_path.slice(prefix.len(), import_path.len())
        relative = relative.replace(".", "/")
        return path.join(context_root, relative)
    }

    fn run_git(arguments: List<string>, cwd: string) -> process.Output {
        var command: process.Command = new process.Command("git")
        for argument: string in arguments {
            command.arg(argument)
        }
        if cwd != "" { command.cwd(cwd) }
        match command.run() {
            ok(output) => { return output }
            err(error) => {
                self.fail(cwd, 0, 0,
                          "could not start git: {error.msg}")
                let failed: process.Output = new process.Output()
                failed.status = -1
                return failed
            }
        }
    }

    fn remove_temporary(dir: string) {
        if !Dir.exists(dir) { return }
        match Dir.remove_all(dir) {
            ok(_) => {}
            err(_) => {}
        }
    }

    fn verify_checkout(dir: string, entry: LockEntry) -> bool {
        let head: process.Output =
            self.run_git(["rev-parse", "HEAD"], dir)
        let tree: process.Output =
            self.run_git(["show", "-s", "--format=%T", "HEAD"], dir)
        if !head.succeeded() || !tree.succeeded() {
            self.fail(dir, 0, 0,
                      "cached checkout is not a readable git repository")
            return false
        }
        if head.stdout_text().trim() != entry.commit {
            self.fail(dir, 0, 0,
                      "cached checkout commit differs from beans.lock")
            return false
        }
        if tree.stdout_text().trim() != entry.tree {
            self.fail(dir, 0, 0,
                      "cached checkout content hash differs from beans.lock")
            return false
        }
        let status: process.Output =
            self.run_git(["status", "--porcelain", "--untracked-files=all"],
                         dir)
        if !status.succeeded() || status.stdout_text().trim() != "" {
            self.fail(dir, 0, 0,
                      "cached checkout has local content changes")
            return false
        }
        return true
    }

    fn ensure_remote(remote_path: string) -> string {
        if !safe_remote_path(remote_path) {
            self.fail(self.root, 0, 0,
                      "unsafe git dependency path '{remote_path}'")
            return ""
        }
        if !self.requirements.contains_key(remote_path) {
            self.fail(
                self.root, 0, 0,
                "dependency {remote_path} is not in beans.pot; run 'beansc pot add {remote_path}'")
            return ""
        }
        let requested: string =
            self.requirements[remote_path]
        let refresh: bool =
            self.lock_mode == "update" &&
            (self.update_module == "" ||
             self.update_module == remote_path)
        let use_lock: bool =
            self.lock_entries.contains_key(remote_path) && !refresh
        var resolved: LockEntry = LockEntry {
            path: remote_path,
            requested: requested,
            commit: "",
            tree: "",
        }
        if use_lock {
            let locked_entry: LockEntry = self.lock_entries[remote_path]
            if locked_entry.requested != requested {
                self.fail(path.join(self.root, "beans.lock"), 0, 0,
                          "dependency {remote_path} now requests {requested} but beans.lock records {locked_entry.requested}")
                return ""
            }
            resolved = locked_entry
        } else if self.locked || self.offline {
            self.fail(path.join(self.root, "beans.lock"), 0, 0,
                      "dependency {remote_path} is missing from beans.lock")
            return ""
        }

        let base: string =
            path.join(path.join(beans_home(), "pkg"), remote_path)
        if use_lock {
            let cached: string = path.join(base, resolved.commit)
            if Dir.exists(cached) {
                if !self.verify_checkout(cached, resolved) { return "" }
                if !File.exists(path.join(cached, "beans.pot")) {
                    self.fail(cached, 0, 0,
                              "cached package has no beans.pot")
                    return ""
                }
                self.resolved_entries[remote_path] = resolved
                return cached
            }
        }
        if self.offline {
            self.fail(self.root, 0, 0,
                      "offline dependency {remote_path} is not present in the content cache")
            return ""
        }

        match Dir.create_all(base) {
            ok(_) => {}
            err(error) => {
                self.fail(base, 0, 0,
                          "cannot create dependency cache: {error.msg}")
                return ""
            }
        }
        self.clone_number += 1
        var nonce: int = 0
        match self.temporary_nonce() {
            some(value) => { nonce = value }
            none => { return "" }
        }
        let temporary: string =
            path.join(base,
                      "clone.tmp-{time.monotonic_millis()}-{nonce}-{self.clone_number}")
        if Dir.exists(temporary) {
            self.fail(temporary, 0, 0,
                      "temporary dependency directory already exists")
            return ""
        }

        var clone_args: List<string> = ["clone", "--quiet"]
        if use_lock || requested != "HEAD" {
            clone_args.push("--no-checkout")
        } else {
            clone_args.push("--depth")
            clone_args.push("1")
        }
        clone_args.push("--")
        clone_args.push("https://{remote_path}.git")
        clone_args.push(temporary)
        let cloned: process.Output = self.run_git(clone_args, "")
        if !cloned.succeeded() {
            self.remove_temporary(temporary)
            self.fail(self.root, 0, 0,
                      "could not fetch {remote_path}")
            return ""
        }

        if use_lock || requested != "HEAD" {
            let checkout_ref: string =
                if use_lock { resolved.commit } else { requested }
            let checkout: process.Output = self.run_git(
                ["-c", "advice.detachedHead=false", "checkout", "--quiet",
                 "--detach", checkout_ref],
                temporary)
            if !checkout.succeeded() {
                self.remove_temporary(temporary)
                self.fail(self.root, 0, 0,
                          "requested ref {checkout_ref} is not available from {remote_path}")
                return ""
            }
        }

        let head: process.Output =
            self.run_git(["rev-parse", "HEAD"], temporary)
        let tree: process.Output =
            self.run_git(["show", "-s", "--format=%T", "HEAD"], temporary)
        resolved.commit = head.stdout_text().trim()
        resolved.tree = tree.stdout_text().trim()
        if !head.succeeded() || !tree.succeeded() ||
           !safe_git_id(resolved.commit) || !safe_git_id(resolved.tree) {
            self.remove_temporary(temporary)
            self.fail(self.root, 0, 0,
                      "could not resolve the commit and content hash for {remote_path}")
            return ""
        }
        if use_lock {
            let locked_entry: LockEntry = self.lock_entries[remote_path]
            if resolved.commit != locked_entry.commit ||
               resolved.tree != locked_entry.tree {
                self.remove_temporary(temporary)
                self.fail(self.root, 0, 0,
                          "fetched dependency does not match beans.lock for {remote_path}")
                return ""
            }
        }

        let checkout_dir: string = path.join(base, resolved.commit)
        if Dir.exists(checkout_dir) {
            self.remove_temporary(temporary)
            if !self.verify_checkout(checkout_dir, resolved) { return "" }
        } else {
            match File.rename(temporary, checkout_dir) {
                ok(_) => {}
                err(error) => {
                    self.remove_temporary(temporary)
                    self.fail(checkout_dir, 0, 0,
                              "could not place dependency in cache: {error.msg}")
                    return ""
                }
            }
        }
        if !File.exists(path.join(checkout_dir, "beans.pot")) {
            self.fail(checkout_dir, 0, 0,
                      "{remote_path} is not a Beans package (no beans.pot)")
            return ""
        }
        self.resolved_entries[remote_path] = resolved
        return checkout_dir
    }

    fn record_file(package: LoadedPackage, parsed: ParsedModuleFile) {
        package.files.push(parsed)
    }

    // A directory is a package when it holds sources; a bare folder of
    // sub-packages (std/encoding) is only a namespace.
    fn dir_has_sources(dir: string) -> bool {
        if !Dir.exists(dir) { return false }
        match Dir.list(dir) {
            ok(names) => {
                for name: string in names {
                    if name.ends_with(".b") { return true }
                }
                return false
            }
            err(_) => { return false }
        }
    }

    // True when `import {…} from P` selects symbols of P itself: P names a
    // loadable package or a native namespace. When P is only a namespace
    // folder (std.encoding), the braces select sub-packages instead and
    // expand_named_imports rewrites the entry before targets are loaded.
    fn import_parent_exists(imported: string, context_name: string,
                            context_root: string) -> bool {
        if imported.starts_with("std.") {
            if native_std_namespace(imported) { return true }
            let standard_root: string =
                if context_name == "std" && context_root != "" {
                    context_root
                } else {
                    stdlib_root()
                }
            let relative: string =
                imported.slice(4, imported.len()).replace(".", "/")
            return self.dir_has_sources(
                path.join(standard_root, relative))
        }
        if context_name != "" && imported == context_name { return true }
        if context_name != "" &&
           imported.starts_with("{context_name}.") {
            return self.dir_has_sources(
                self.local_import_dir(imported, context_name,
                                      context_root))
        }
        // Local and git dependencies are imported by module name, which
        // always names a real package root; their braces select symbols.
        return true
    }

    // `import {json, xml} from std.encoding` groups sub-packages of a
    // folder that is not itself a package. Each selected name becomes its
    // own import of `P.name`, bound by the written name, so that after
    // this pass a named list always selects symbols of a real target.
    fn expand_named_imports(file: ParsedModuleFile, context_name: string,
                            context_root: string) {
        var needs_rewrite: bool = false
        for entry: ModuleImport in file.imports {
            if entry.names.len() != 0 &&
               !self.import_parent_exists(entry.path, context_name,
                                          context_root) {
                needs_rewrite = true
            }
        }
        if !needs_rewrite { return }
        var expanded: List<ModuleImport> = []
        for entry: ModuleImport in file.imports {
            if entry.names.len() == 0 ||
               self.import_parent_exists(entry.path, context_name,
                                         context_root) {
                expanded.push(entry)
                continue
            }
            for named: NamedImport in entry.names {
                let bound_name: string =
                    if named.alias != "" {
                        named.alias
                    } else {
                        named.name
                    }
                let sub: ModuleImport =
                    new ModuleImport("{entry.path}.{named.name}",
                                     bound_name, entry.node)
                sub.line = named.line
                sub.col = named.col
                expanded.push(sub)
            }
        }
        file.imports = move expanded
    }

    fn resolve_package_imports(package: LoadedPackage, dir: string,
                               context_name: string, context_root: string,
                               context_canon: string,
                               entry_app: bool) {
        for file: ParsedModuleFile in package.files {
            self.expand_named_imports(file, context_name, context_root)
        }
        for file: ParsedModuleFile in package.files {
            for entry: ModuleImport in file.imports {
                let imported: string = entry.path
                if imported.starts_with("std.") {
                    let standard_root: string =
                        if context_name == "std" && context_root != "" {
                            context_root
                        } else {
                            stdlib_root()
                        }
                    let relative: string =
                        imported.slice(4, imported.len()).replace(".", "/")
                    let standard_dir: string =
                        path.join(standard_root, relative)
                    if Dir.exists(standard_dir) {
                        entry.resolved = imported
                        entry.node.resolved = imported
                        package.imports.push(imported)
                        self.load_package(imported, standard_dir,
                                          "std", standard_root, "",
                                          file.path, entry.line, entry.col)
                    } else if !native_std_namespace(imported) {
                        self.fail(
                            file.path, entry.line, entry.col,
                            "no module '{imported}'")
                    }
                    continue
                }
                if context_name != "" &&
                   (imported == context_name ||
                    imported.starts_with("{context_name}.")) {
                    if imported == context_name {
                        if entry_app {
                            entry.resolved = imported
                            entry.node.resolved = imported
                            package.imports.push(imported)
                            self.load_package(
                                imported, context_root,
                                context_name, context_root, context_canon,
                                file.path, entry.line, entry.col)
                        } else {
                            self.fail(
                                file.path, entry.line, entry.col,
                                "a package cannot import its own module root")
                        }
                        continue
                    }
                    let imported_dir: string =
                        self.local_import_dir(imported, context_name,
                                              context_root)
                    let relative: string =
                        imported.slice(context_name.len() + 1,
                                       imported.len()).replace(".", "/")
                    if !Dir.exists(imported_dir) {
                        self.fail(
                            file.path, entry.line, entry.col,
                            "package directory {relative} doesn't exist")
                        continue
                    }
                    // inside a git checkout, `dep.sub` and the app's
                    // `github.com/x/dep/sub` are the same directory — one
                    // canonical identity, or the program loads it twice
                    let canonical: string =
                        if context_canon == "" {
                            imported
                        } else {
                            path.join(context_canon, relative)
                        }
                    entry.resolved = canonical
                    entry.node.resolved = canonical
                    package.imports.push(canonical)
                    self.load_package(canonical, imported_dir,
                                      context_name, context_root,
                                      context_canon,
                                      file.path, entry.line, entry.col)
                    continue
                }

                // A local path dependency is imported by the module name in
                // its own beans.pot, never by ../ filesystem syntax.
                let first_part: string = imported.split(".")[0]
                let dependency_root: string =
                    self.local_modules.get(
                        local_module_key(context_root, first_part)).or("")
                if dependency_root != "" {
                    var dependency_name: string =
                        self.local_names.get(dependency_root).or("")
                    if dependency_name == "" {
                        dependency_name =
                            self.read_module_name(dependency_root)
                        if dependency_name == "" { continue }
                        self.local_names[dependency_root] = dependency_name
                    }
                    let imported_dir: string =
                        self.local_import_dir(
                            imported, dependency_name, dependency_root)
                    entry.resolved = imported
                    entry.node.resolved = imported
                    package.imports.push(imported)
                    self.load_package(
                        imported, imported_dir,
                        dependency_name, dependency_root, "",
                        file.path, entry.line, entry.col)
                    continue
                }

                let remote_parts: List<string> = imported.split("/")
                if remote_parts.len() >= 3 &&
                   remote_parts[0].contains(".") {
                    let remote_path: string =
                        "{remote_parts[0]}/{remote_parts[1]}/{remote_parts[2]}"
                    let checkout: string = self.ensure_remote(remote_path)
                    if checkout == "" { continue }
                    var remote_name: string =
                        self.remote_names.get(checkout).or("")
                    if remote_name == "" {
                        remote_name = self.read_module_name(checkout)
                        if remote_name == "" { continue }
                        self.remote_names[checkout] = remote_name
                    }
                    var imported_dir: string = checkout
                    for index: int in 3..remote_parts.len() {
                        imported_dir =
                            path.join(imported_dir, remote_parts[index])
                    }
                    entry.resolved = imported
                    entry.node.resolved = imported
                    package.imports.push(imported)
                    self.load_package(imported, imported_dir,
                                      remote_name, checkout, remote_path,
                                      file.path, entry.line, entry.col)
                    continue
                }

                if context_name == "" {
                    self.fail(file.path, entry.line, entry.col,
                              "unknown package '{imported}' — local packages need a beans.pot")
                } else {
                    self.fail(file.path, entry.line, entry.col,
                              "unknown package '{imported}' — expected std.*, {context_name}.*, or a git host path")
                }
            }
        }
    }

    fn push_stack(import_path: string, from_file: string, line: int) {
        var from: string = ""
        if self.stack.len() != 0 {
            from = self.stack[self.stack.len() - 1]
        }
        self.stack.push(import_path)
        self.stack_edges.push(ImportEdge {
            from: from,
            to: import_path,
            file: from_file,
            line: line,
        })
    }

    fn pop_stack() {
        self.stack.pop()
        self.stack_edges.pop()
    }

    fn load_package(import_path: string, dir: string,
                    context_name: string, context_root: string,
                    context_canon: string, from_file: string,
                    line: int, col: int) {
        let status: int = self.state.get(import_path).or(0)
        // one instance per Package ID; same-name packages at different
        // paths are separate and never land here
        if status == 2 { return }
        if status == 1 {
            self.report_cycle(import_path, from_file, line, col)
            return
        }
        self.state[import_path] = 1
        self.push_stack(import_path, from_file, line)

        if !Dir.exists(dir) {
            self.fail(from_file, line, col,
                      "package directory does not exist")
            self.state[import_path] = 2
            self.pop_stack()
            return
        }
        let package: LoadedPackage =
            new LoadedPackage(import_path, dir)
        var names: List<string> = Dir.list(dir).expect("list package")
        names.sort()
        for name: string in names {
            if !name.ends_with(".b") { continue }
            // The async runtime's readiness half only loads when the
            // program can reach it (see load_async_runtime): a pure
            // async program must not emit or link poller symbols.
            if import_path == async_rt_package() &&
               name == "reactor.b" && !self.want_reactor {
                continue
            }
            if import_path == async_rt_package() &&
               (name == "thread_basic.b" ||
                name == "thread_reactor.b") {
                if !self.want_async_thread {
                    continue
                }
                if (name == "thread_reactor.b") !=
                   self.want_reactor {
                    continue
                }
            }
            let file_path: string = path.join(dir, name)
            let parsed: ParsedModuleFile = self.parse_file(file_path)
            self.record_file(package, parsed)
        }
        if package.files.len() == 0 {
            self.fail(from_file, line, col,
                      "package has no .b files")
        }
        self.check_package_clause(package, "imported")
        self.package_names[import_path] = package.name

        self.resolve_package_imports(package, dir, context_name,
                                     context_root, context_canon, false)
        self.packages.push(package)
        self.state[import_path] = 2
        self.pop_stack()
    }

    // Any program that declares an async function needs the internal task
    // package. Its directory name cannot be spelled in source — the
    // compiler is the only importer.
    fn load_async_runtime() {
        var wanted: bool = false
        for package: LoadedPackage in self.packages {
            for file: ParsedModuleFile in package.files {
                for imported: ModuleImport in file.imports {
                    if imported.path == "std.thread" {
                        self.want_async_thread = true
                    }
                }
                for declaration: AstNode in file.ast.children {
                    if ast_needs_async_runtime(declaration) {
                        wanted = true
                    }
                }
            }
        }
        if !wanted { return }
        let standard_root: string =
            if self.module_name == "std" && self.root != "" {
                self.root
            } else {
                stdlib_root()
            }
        let dir: string = path.join(standard_root, "async$rt")
        if !Dir.exists(dir) {
            // 1:1, not 0:0: both compilers render a real position the same
            // way, so this installation error stays byte-identical too.
            self.fail(dir, 1, 1,
                      "the async runtime package is missing from the standard library")
            return
        }
        // The readiness half (reactor.b) rides along only when std.net is
        // loaded — net.readable / net.writable are the only
        // operations that can park an await, and they cannot be named
        // without that import. Everything the loader loads is emitted, so
        // this is what keeps poller symbols out of pure async programs and
        // lets them link under the minimal and freestanding profiles.
        self.want_reactor =
            self.state.get("std.net").or(0) == 2
        self.load_package(async_rt_package(), dir,
                          "std", standard_root, "", "", 1, 1)
    }

    // The root package: the same directory walk as an imported one, but its
    // clause obeys the manifest's kind instead of the imported-package rule.
    fn load_root_package() {
        self.state[self.module_name] = 1
        self.push_stack(self.module_name, self.root, 1)
        let package: LoadedPackage =
            new LoadedPackage(self.module_name, self.root)
        var names: List<string> = Dir.list(self.root).expect("list package")
        names.sort()
        for name: string in names {
            if !name.ends_with(".b") { continue }
            let file_path: string = path.join(self.root, name)
            self.record_file(package, self.parse_file(file_path))
        }
        if package.files.len() == 0 {
            self.fail(self.root, 0, 0, "package has no .b files")
        }
        var role: string = "root_application"
        if self.kind == "library" { role = "root_library" }
        self.check_package_clause(package, role)
        self.package_names[self.module_name] = package.name
        self.resolve_package_imports(package, self.root,
                                     self.module_name, self.root, "", false)
        self.pop_stack()
        self.packages.push(package)
        self.state[self.module_name] = 2
        if self.entry_package == "" {
            self.entry_package = self.module_name
        }
    }

    fn is_library_entry(entry: string) -> bool {
        if self.kind != "library" || !entry.ends_with(".b") { return false }
        let normalized_entry: string = absolute_local_path(entry)
        let normalized_root: string = absolute_local_path(self.root)
        var relative: string = ""
        if normalized_root == "." && !normalized_entry.starts_with("/") {
            relative = normalized_entry
        } else {
            let prefix: string = "{normalized_root}/"
            if !normalized_entry.starts_with(prefix) { return false }
            relative = normalized_entry.slice(prefix.len(),
                                                normalized_entry.len())
        }
        let first: string = relative.split("/")[0]
        return first == "examples" || first == "tests"
    }

    fn load_library_entry(entry: string) {
        let entry_id: string = "{self.module_name}$entry"
        var entry_dir: string = path.parent(entry)
        if entry_dir == "" { entry_dir = "." }
        self.state[entry_id] = 1
        self.push_stack(entry_id, entry, 1)
        let package: LoadedPackage =
            new LoadedPackage(entry_id, entry_dir)
        if path.name(entry) == "main.b" {
            var names: List<string> =
                Dir.list(entry_dir).expect("list entry package")
            names.sort()
            for name: string in names {
                if name.ends_with(".b") {
                    self.record_file(
                        package,
                        self.parse_file(path.join(entry_dir, name)))
                }
            }
        } else {
            self.record_file(package, self.parse_file(entry))
        }
        self.check_package_clause(package, "root_application")
        self.package_names[entry_id] = package.name
        self.resolve_package_imports(
            package, entry_dir, self.module_name, self.root, "", true)
        self.pop_stack()
        self.packages.push(package)
        self.state[entry_id] = 2
        self.entry_package = entry_id
        self.kind = "application"
    }

    fn load(entry: string) -> bool {
        self.root = self.find_root(entry)
        if self.root == "" {
            if self.locked || self.offline {
                self.fail(entry, 0, 0,
                          "dependency lock options need a beans.pot project")
                return false
            }
            let standard_package: string =
                stdlib_source_package(entry)
            if standard_package != "" {
                self.module_name = "std"
                self.entry_package = standard_package
                self.kind = "library"
                self.root = stdlib_source_root(entry)
                var package_dir: string = path.parent(entry)
                if package_dir == "" { package_dir = "." }
                self.load_package(
                    standard_package, package_dir,
                    "std", self.root, "", entry, 1, 1)
                self.load_async_runtime()
                self.bind_imports()
                return self.errors.len() == 0
            }
            self.module_name = "main"
            self.entry_package = "main"
            let package: LoadedPackage =
                new LoadedPackage("main", path.parent(entry))
            self.record_file(package, self.parse_file(entry))
            self.state["main"] = 1
            self.push_stack("main", entry, 1)
            self.check_package_clause(package, "single_file")
            self.package_names["main"] = package.name
            self.resolve_package_imports(package, path.parent(entry),
                                         "", "", "", false)
            self.pop_stack()
            self.packages.push(package)
            self.state["main"] = 2
            self.load_async_runtime()
            self.bind_imports()
            return self.errors.len() == 0
        }

        self.module_name = self.read_module_name(self.root)
        self.local_name_roots[self.module_name] = self.root
        self.read_lock(self.root)
        if self.errors.len() != 0 { return false }
        var entry_dir: string = path.parent(entry)
        if entry_dir == "" { entry_dir = "." }
        let library_entry: bool = self.is_library_entry(entry)
        if entry_dir != self.root && !library_entry {
            self.fail(entry, 0, 0,
                      "entry file must sit next to beans.pot")
            return false
        }
        self.load_root_package()
        if library_entry { self.load_library_entry(entry) }
        self.load_async_runtime()
        self.bind_imports()
        if self.locked || self.offline {
            for locked_path: string in self.lock_entries.keys() {
                if !self.resolved_entries.contains_key(locked_path) {
                    self.fail(path.join(self.root, "beans.lock"), 0, 0,
                              "beans.lock contains unused dependency {locked_path}")
                }
            }
        }
        if self.errors.len() == 0 && self.lock_mode != "use" {
            if self.update_module != "" &&
               !self.resolved_entries.contains_key(self.update_module) {
                if self.requirements.contains_key(self.update_module) {
                    self.ensure_remote(self.update_module)
                } else {
                    self.fail(path.join(self.root, "beans.pot"), 0, 0,
                              "cannot update unknown dependency {self.update_module}")
                }
            }
            if self.errors.len() == 0 { self.write_lock() }
        }
        return self.errors.len() == 0
    }
}

fn render_module_graph(loader: ModuleLoader) -> string {
    var out: string =
        "module {loader.module_name} kind={loader.kind} root={loader.root}"
    for package: LoadedPackage in loader.packages {
        out = "{out}\npackage {package.import_path} name={package.name}"
        // Imports sit under the file that wrote them: a binding belongs to
        // one file, never to the package.
        for file: ParsedModuleFile in package.files {
            out = "{out}\n  file {file.path}"
            for imported: ModuleImport in file.imports {
                var target: string = imported.resolved
                if target == "" { target = imported.path }
                out =
                    "{out}\n    import {target} as {imported.binding}"
            }
        }
    }
    return out
}
