package main

import std.path

fn semantic_import_completion_context(
    text: string, line: int,
    col: int) -> SemanticImportCompletionContext {
    let context: SemanticImportCompletionContext =
        new SemanticImportCompletionContext()
    let lines: List<string> = text.split("\n")
    if line <= 0 || line > lines.len() { return context }
    let source: string = lines[line - 1]
    var end: int = col - 1
    if end < 0 { end = 0 }
    if end > source.len() { end = source.len() }
    let before: string = source.slice(0, end).trim_start()
    if !before.starts_with("import ") { return context }
    let written: string =
        before.slice(7, before.len()).trim()
    if written == "" || written.contains(" ") { return context }
    context.active = true
    match written.rfind(".") {
        some(dot) => {
            context.parent = written.slice(0, dot + 1)
            context.prefix = written.slice(dot + 1, written.len())
        }
        none => { context.prefix = written }
    }
    return context
}

// Source-backed standard packages come from the installed standard library.
// Native packages have no directory, so keep their public names here too.
fn semantic_std_import_paths() -> List<string> {
    var packages: List<string> = [
        "std.asm", "std.c", "std.cpu", "std.dl",
        "std.intrinsic", "std.io", "std.os", "std.process",
        "std.random", "std.signal", "std.sock", "std.target",
        "std.thread", "std.time"]
    let root: string = stdlib_root()
    if Dir.exists(root) {
        match Dir.walk(root) {
            ok(files) => {
                for relative: string in files {
                    if !relative.ends_with(".b") { continue }
                    let directory: string = path.parent(relative)
                    if directory == "" || directory == "." ||
                       directory.contains("$") {
                        continue
                    }
                    let package_path: string =
                        "std.{directory.replace("/", ".")}"
                    if !packages.contains(package_path) {
                        packages.push(package_path)
                    }
                }
            }
            err(problem) => {}
        }
    }
    packages.sort()
    return move packages
}

// Every import path the current project can name. Loaded packages cover
// dependencies and packages already used by another file. Walking the local
// module also finds packages while their first import is still being typed.
fn semantic_import_paths(
    snapshot: SemanticSnapshot) -> List<string> {
    var packages: List<string> = semantic_std_import_paths()
    for package: LoadedPackage in snapshot.loader.packages {
        if !packages.contains(package.import_path) {
            packages.push(package.import_path)
        }
    }
    let root: string = snapshot.loader.root
    let module_name: string = snapshot.loader.module_name
    if root != "" && module_name != "" && Dir.exists(root) {
        match Dir.walk(root) {
            ok(files) => {
                for relative: string in files {
                    if !relative.ends_with(".b") { continue }
                    var directory: string = path.parent(relative)
                    if directory == "" || directory == "." { continue }
                    directory = directory.replace("\\", "/")
                    let package_path: string =
                        "{module_name}.{directory.replace("/", ".")}"
                    if !packages.contains(package_path) {
                        packages.push(package_path)
                    }
                }
            }
            err(problem) => {}
        }
    }
    packages.sort()
    return move packages
}

fn semantic_import_completions(
    snapshot: SemanticSnapshot,
    context: SemanticImportCompletionContext) -> List<SemanticCompletion> {
    var items: List<SemanticCompletion> = []
    var seen: Map<string, bool> = {}
    for package_path: string in semantic_import_paths(snapshot) {
        if !package_path.starts_with(context.parent) { continue }
        let rest: string =
            package_path.slice(context.parent.len(), package_path.len())
        if rest == "" { continue }
        let label: string = rest.split(".")[0]
        if !semantic_prefix_matches(context.prefix, label) { continue }
        if label.contains("$") || seen.contains_key(label) { continue }
        seen[label] = true
        let item: SemanticCompletion =
            new SemanticCompletion(
                label, "module", "import:{context.parent}{label}")
        item.detail = "import {context.parent}{label}"
        items.push(item)
    }
    return move items
}
