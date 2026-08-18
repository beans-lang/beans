package main

import std.path

// The project a file belongs to: the directory holding its `beans.pot`, or the
// file itself when it stands alone. Two files of one module share a snapshot,
// so opening a second file of a project costs nothing.
fn semantic_project_key(file_path: string) -> string {
    if stdlib_source_package(file_path) != "" {
        return path.parent(file_path)
    }
    var dir: string = path.parent(file_path)
    if dir == "" { dir = "." }
    for true {
        if File.exists(path.join(dir, "beans.pot")) { return dir }
        let parent: string = path.parent(dir)
        if parent == "" || parent == dir { break }
        dir = parent
    }
    dir = path.parent(absolute_local_path(file_path))
    for true {
        if File.exists(path.join(dir, "beans.pot")) { return dir }
        let parent: string = path.parent(dir)
        if parent == "" || parent == dir { break }
        dir = parent
    }
    return file_path
}

// One live view of every open document and the projects they belong to.
//
// A snapshot is built once per project per revision and then reused by every
// query. Editing any document bumps the revision, which is the only thing that
// can invalidate a snapshot; a run of hovers, completions and navigations
// between two keystrokes all share one check.
class SemanticWorkspace {
    documents: Map<string, LspDocument>
    revision: int
    // project key -> the snapshot built for it
    snapshots: Map<string, SemanticSnapshot>
    // project key -> the newest snapshot that checked cleanly, kept so an
    // editor keeps working while the buffer is briefly broken
    good: Map<string, SemanticSnapshot>
    // project key -> the entry file its snapshot was built from
    entries: Map<string, string>
    // how many times the pipeline actually ran; a test can prove reuse
    builds: int

    fn init() {
        self.documents = {}
        self.revision = 1
        self.snapshots = {}
        self.good = {}
        self.entries = {}
        self.builds = 0
    }

    fn touch() {
        self.revision += 1
    }

    fn overlays() -> Map<string, string> {
        var result: Map<string, string> = {}
        for uri: string in self.documents.keys() {
            let document: LspDocument = self.documents[uri]
            result[document.path] = document.text
        }
        return move result
    }

    // The snapshot covering `file_path`, building one only when the workspace
    // moved on since the last build.
    fn snapshot(file_path: string) -> SemanticSnapshot {
        let key: string = semantic_project_key(file_path)
        match self.snapshots.get(key) {
            some(existing) => {
                if existing.revision == self.revision &&
                   existing.has_file(file_path) {
                    return existing
                }
            }
            none => {}
        }
        var entry: string = file_path
        if key != file_path {
            entry = self.entry_for(key, file_path)
        }
        let built: SemanticSnapshot =
            semantic_build(entry, self.overlays(), self.revision)
        self.builds += 1
        self.snapshots[key] = built
        self.entries[key] = entry
        if built.checked { self.good[key] = built }
        return built
    }

    // The newest snapshot of this project that checked cleanly, or the
    // current one when there is none.
    fn last_good(file_path: string) -> SemanticSnapshot {
        let key: string = semantic_project_key(file_path)
        match self.good.get(key) {
            some(found) => {
                if found.has_file(file_path) { return found }
            }
            none => {}
        }
        return self.snapshot(file_path)
    }

    // A module's entry is the file beside `beans.pot` that names the module.
    // Loading through it brings in every package the project uses, which is
    // what makes cross-package navigation work from any open file.
    fn entry_for(root: string, file_path: string) -> string {
        for candidate: string in ["main.b", "lib.b"] {
            let full: string = path.join(root, candidate)
            if File.exists(full) { return full }
        }
        return file_path
    }

    fn open(uri: string, file_path: string, text: string) {
        self.documents[uri] =
            new LspDocument(uri, file_path, text)
        self.touch()
    }

    fn close(uri: string) {
        if !self.documents.contains_key(uri) { return }
        self.documents.remove(uri)
        self.touch()
    }

    fn text_of(uri: string) -> string {
        match self.documents.get(uri) {
            some(document) => { return document.text }
            none => { return "" }
        }
    }
}

// ---------------------------------------------------------------------------
// Finding the projects in a workspace
// ---------------------------------------------------------------------------

// Directories a source walk never descends into. None of them holds project
// sources, and `.git` alone can hold tens of thousands of files.
fn semantic_skipped_directory(name: string) -> bool {
    return name.starts_with(".") || name == "node_modules" ||
           name == "build" || name == "target" ||
           name == "dist" || name == "out"
}

fn semantic_walk_skipped(relative: string) -> bool {
    for part: string in relative.split("/") {
        if semantic_skipped_directory(part) { return true }
    }
    return false
}

// The entry file of every Beans project under `root`.
//
// A project is a directory holding `beans.pot`; its entry is the file beside
// it that the loader would start from. A workspace with no manifest at all
// falls back to its loose `.b` files, so a single-file scratch folder still
// answers workspace queries.
fn semantic_discover_projects(root: string,
                              limit: int) -> List<string> {
    var entries: List<string> = []
    if root == "" || !Dir.exists(root) { return move entries }
    var files: List<string> = []
    match Dir.walk(root) {
        ok(found) => {
            for name: string in found { files.push(name) }
        }
        err(problem) => { return move entries }
    }
    var project_dirs: List<string> = []
    var loose: List<string> = []
    for relative: string in files {
        if semantic_walk_skipped(relative) { continue }
        let full: string = path.join(root, relative)
        if path.name(relative) == "beans.pot" {
            let dir: string = path.parent(full)
            if !project_dirs.contains(dir) {
                project_dirs.push(dir)
            }
            continue
        }
        if relative.ends_with(".b") { loose.push(full) }
    }
    for dir: string in project_dirs {
        if entries.len() >= limit { break }
        entries.push(semantic_project_entry(dir))
    }
    for file_path: string in loose {
        if entries.len() >= limit { break }
        // A file inside a project is already covered by that project's entry.
        var covered: bool = false
        for dir: string in project_dirs {
            if file_path.starts_with("{dir}/") { covered = true }
        }
        if covered { continue }
        entries.push(file_path)
    }
    return move entries
}

// The file a project is loaded through: `main.b`, then `lib.b`, then whatever
// `.b` sits beside the manifest.
fn semantic_project_entry(dir: string) -> string {
    for candidate: string in ["main.b", "lib.b"] {
        let full: string = path.join(dir, candidate)
        if File.exists(full) { return full }
    }
    match Dir.list(dir) {
        ok(names) => {
            for name: string in names {
                if name.ends_with(".b") {
                    return path.join(dir, name)
                }
            }
        }
        err(problem) => {}
    }
    return path.join(dir, "main.b")
}
