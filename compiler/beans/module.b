package main

import std.fs
import std.os
import std.path
import std.process
import std.random

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

// One import written in one file. The source spelling is kept apart from the
// canonical target: a local import inside a git checkout resolves onto the
// path its dependents use, and diagnostics still show what was written.
class ModuleImport {
    path: string      // verbatim source spelling
    alias: string     // `as` name, "" if none
    resolved: string  // canonical Package ID, "" for a native std namespace
    binding: string   // the name this import binds in its own file
    node: AstNode
    line: int
    col: int

    fn init(path: string, alias: string, node: AstNode) {
        self.path = path
        self.alias = alias
        self.resolved = ""
        self.binding = ""
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

// The final segment of an import path. Only a native std namespace with no
// source package uses this as its name; every loaded package declares one.
fn last_path_segment(import_path: string) -> string {
    let parts: List<string> = import_path.replace("/", ".").split(".")
    return parts[parts.len() - 1]
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

class ModuleLoader {
    sources: SourceManager
    module_name: string
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
    links: List<ModuleLink>
    overlays: Map<string, string>
    want_reactor: bool
    // The depth-first stack of packages being loaded, and the import edge
    // that pushed each one (stack_edges[i] led to stack[i]).
    stack: List<string>
    stack_edges: List<ImportEdge>

    fn init(sources: SourceManager, locked: bool, offline: bool,
            lock_mode: string, update_module: string) {
        self.sources = sources
        self.module_name = ""
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
        self.links = []
        self.overlays = {}
        self.want_reactor = false
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
            if parent == "" || parent == dir { return "" }
            dir = parent
        }
        return ""
    }

    fn read_module_name(root: string) -> string {
        let mod_path: string = path.join(root, "beans.pot")
        let text: string = fs.read(mod_path).expect("read beans.pot")
        var name: string = ""
        var manifest_kind: string = "application"
        var saw_kind: bool = false
        for line: string in text.lines() {
            let words: List<string> = module_words(line)
            if words.len() == 0 || words[0].starts_with("//") {
                continue
            }
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
            } else if words[0] == "require" && words.len() == 3 {
                let required_path: string = words[1]
                let requested: string = words[2]
                let previous: string =
                    self.requirements.get(required_path).or("")
                if previous != "" && previous != requested {
                    self.fail(mod_path, 0, 0,
                              "dependency {required_path} is required at both {previous} and {requested}")
                } else {
                    self.requirements[required_path] = requested
                }
            } else if words[0] == "link" && words.len() == 4 {
                let selector: string = words[1]
                let kind: string = words[2]
                let quoted: string = words[3]
                if kind != "search" && kind != "library" &&
                   kind != "framework" {
                    self.fail(
                        mod_path, 0, 0,
                        "link kind must be search, library, or framework")
                } else if quoted.len() < 2 ||
                          !quoted.starts_with("\"") ||
                          !quoted.ends_with("\"") {
                    self.fail(
                        mod_path, 0, 0,
                        "link value must be a quoted string")
                } else {
                    self.links.push(ModuleLink {
                        selector: selector,
                        kind: kind,
                        value:
                            quoted.slice(1, quoted.len() - 1),
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
        var arguments: List<string> = []
        for link: ModuleLink in self.links {
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

    fn read_lock(root: string) {
        let lock_path: string = path.join(root, "beans.lock")
        if !File.exists(lock_path) {
            if self.offline {
                self.fail(lock_path, 0, 0,
                          "offline dependency loading needs a committed beans.lock")
            } else if self.locked {
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
            if self.lock_entries.contains(words[1]) {
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
            "{lock_path}.tmp-{os.ticks_ms()}-{nonce}"
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
            parsed.imports.push(
                new ModuleImport(imported, alias, declaration))
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
        if !head.ok() || !tree.ok() {
            self.fail(dir, 0, 0,
                      "cached checkout is not a readable git repository")
            return false
        }
        if head.text().trim() != entry.commit {
            self.fail(dir, 0, 0,
                      "cached checkout commit differs from beans.lock")
            return false
        }
        if tree.text().trim() != entry.tree {
            self.fail(dir, 0, 0,
                      "cached checkout content hash differs from beans.lock")
            return false
        }
        let status: process.Output =
            self.run_git(["status", "--porcelain", "--untracked-files=all"],
                         dir)
        if !status.ok() || status.text().trim() != "" {
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
        let requested: string =
            self.requirements.get(remote_path).or("HEAD")
        let refresh: bool =
            self.lock_mode == "update" &&
            (self.update_module == "" ||
             self.update_module == remote_path)
        let use_lock: bool =
            self.lock_entries.contains(remote_path) && !refresh
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

        match Dir.make_all(base) {
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
                      "clone.tmp-{os.ticks_ms()}-{nonce}-{self.clone_number}")
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
        if !cloned.ok() {
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
            if !checkout.ok() {
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
        resolved.commit = head.text().trim()
        resolved.tree = tree.text().trim()
        if !head.ok() || !tree.ok() ||
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

    fn resolve_package_imports(package: LoadedPackage, dir: string,
                               context_name: string, context_root: string,
                               context_canon: string) {
        for file: ParsedModuleFile in package.files {
            for entry: ModuleImport in file.imports {
                let imported: string = entry.path
                if imported.starts_with("std.") {
                    let standard_root: string = stdlib_root()
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
                    }
                    // a missing directory may still be a native std namespace
                    continue
                }
                if context_name != "" &&
                   (imported == context_name ||
                    imported.starts_with("{context_name}.")) {
                    if imported == context_name {
                        self.fail(file.path, entry.line, entry.col,
                                  "a package cannot import its own module root")
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
                                     context_root, context_canon)
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
                for declaration: AstNode in file.ast.children {
                    if declaration.kind == "fn" &&
                       value_marks_async(declaration.value) {
                        wanted = true
                    }
                    if declaration.kind == "class" ||
                       declaration.kind == "interface" ||
                       declaration.kind == "enum" {
                        for member: AstNode in declaration.children {
                            if member.kind == "fn" &&
                               value_marks_async(member.value) {
                                wanted = true
                            }
                        }
                    }
                }
            }
        }
        if !wanted { return }
        let dir: string =
            path.join(stdlib_root(), "async$rt")
        if !Dir.exists(dir) {
            // 1:1, not 0:0: both compilers render a real position the same
            // way, so this installation error stays byte-identical too.
            self.fail(dir, 1, 1,
                      "the async runtime package is missing from the standard library")
            return
        }
        // The readiness half (reactor.b) rides along only when std.net is
        // loaded — net.await_readable / net.await_writable are the only
        // operations that can park an await, and they cannot be named
        // without that import. Everything the loader loads is emitted, so
        // this is what keeps poller symbols out of pure async programs and
        // lets them link under the minimal and freestanding profiles.
        self.want_reactor =
            self.state.get("std.net").or(0) == 2
        self.load_package(async_rt_package(), dir,
                          "std", stdlib_root(), "", "", 1, 1)
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
                                     self.module_name, self.root, "")
        self.pop_stack()
        self.packages.push(package)
        self.state[self.module_name] = 2
    }

    fn load(entry: string) -> bool {
        self.root = self.find_root(entry)
        if self.root == "" {
            if self.locked || self.offline {
                self.fail(entry, 0, 0,
                          "dependency lock options need a beans.pot project")
                return false
            }
            self.module_name = "main"
            let package: LoadedPackage =
                new LoadedPackage("main", path.parent(entry))
            self.record_file(package, self.parse_file(entry))
            self.state["main"] = 1
            self.push_stack("main", entry, 1)
            self.check_package_clause(package, "single_file")
            self.package_names["main"] = package.name
            self.resolve_package_imports(package, path.parent(entry),
                                         "", "", "")
            self.pop_stack()
            self.packages.push(package)
            self.state["main"] = 2
            self.load_async_runtime()
            self.bind_imports()
            return self.errors.len() == 0
        }

        self.module_name = self.read_module_name(self.root)
        self.read_lock(self.root)
        if self.errors.len() != 0 { return false }
        var entry_dir: string = path.parent(entry)
        if entry_dir == "" { entry_dir = "." }
        if entry_dir != self.root {
            self.fail(entry, 0, 0,
                      "entry file must sit next to beans.pot")
            return false
        }
        self.load_root_package()
        self.load_async_runtime()
        self.bind_imports()
        if self.locked || self.offline {
            for locked_path: string in self.lock_entries.keys() {
                if !self.resolved_entries.contains(locked_path) {
                    self.fail(path.join(self.root, "beans.lock"), 0, 0,
                              "beans.lock contains unused dependency {locked_path}")
                }
            }
        }
        if self.errors.len() == 0 && self.lock_mode != "use" {
            if self.update_module != "" &&
               !self.resolved_entries.contains(self.update_module) {
                self.fail(path.join(self.root, "beans.pot"), 0, 0,
                          "cannot update unknown dependency {self.update_module}")
            } else {
                self.write_lock()
            }
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
