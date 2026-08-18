package main

import std.fs
import std.os
import std.path
import std.process
import std.random
import std.time

// `csrc` manifest rows: C sources a package declares so the toolchain can
// build them itself — no vendored per-target binaries, no external make
// step. The native driver compiles each file to a cached object with the
// build's own flags; `beansc run` compiles the whole set once into a host
// shared library and resolves extern symbols through it, the same way it
// treats a manifest `link` library.

fn csrc_selected(rows: List<ModuleLink>,
                 target: TargetDescription) -> List<string> {
    var sources: List<string> = []
    for row: ModuleLink in rows {
        if row.selector == "all" ||
           row.selector == target.os ||
           row.selector == target.triple {
            sources.push(path.join(row.root, row.value))
        }
    }
    return move sources
}

// Two independent hashes plus the byte length make accidental cache aliases
// far less likely than the old single 31-bit rolling hash. A cache hit is a
// correctness decision -- loading an unrelated C library because two inputs
// collided is not an acceptable performance shortcut.
fn csrc_key_tag(key: string) -> string {
    var first: int = 0
    var second: int = 17
    for index: int in 0..key.len() {
        let byte: int = key.byte_at(index)
        first =
            (first * 131 + byte) %
            2147483647
        second =
            (second * 257 + byte + index % 251) %
            2147483629
    }
    return "{first}x{second}x{key.len()}"
}

// `path.join` deliberately does not canonicalize. Includes need a stable
// spelling so `native/../include/x.h` and `include/x.h` cannot make the
// dependency walk visit one file twice or loop forever through guarded
// headers.
fn csrc_normalize_path(value: string) -> string {
    let absolute: bool = value.starts_with("/")
    var parts: List<string> = []
    for part: string in value.split("/") {
        if part == "" || part == "." { continue }
        if part == ".." {
            if parts.len() > 0 && parts[parts.len() - 1] != ".." {
                parts.remove(parts.len() - 1)
            } else if !absolute {
                parts.push(part)
            }
        } else {
            parts.push(part)
        }
    }
    var out: string = if absolute { "/" } else { "" }
    for index: int in 0..parts.len() {
        if index != 0 { out = "{out}/" }
        out = "{out}{parts[index]}"
    }
    return out
}

// Returns the path inside a quoted local include, or empty for system,
// macro, and non-include lines. Clang itself owns C parsing; this only finds
// the local files whose contents must enter the cache key.
fn csrc_quoted_include(line: string) -> string {
    var rest: string = line.trim()
    if !rest.starts_with("#") { return "" }
    rest = rest.slice(1, rest.len()).trim()
    if !rest.starts_with("include") { return "" }
    rest = rest.slice(7, rest.len()).trim()
    if rest.len() < 2 || rest.byte_at(0) != 34 { return "" }
    let tail: string = rest.slice(1, rest.len())
    match tail.find("\"") {
        some(end) => { return tail.slice(0, end) }
        none => { return "" }
    }
}

// Hash the source and every recursively quoted local header. The old cache
// used only the .c text, so changing `fast_add.h` silently reused code built
// from the old constant. Missing includes remain Clang errors; only files
// that exist beside the source take part here.
fn csrc_dependency_key(source: string,
                       seen: List<string>) -> Result<string> {
    let normalized: string = csrc_normalize_path(source)
    if seen.contains(normalized) { return ok("") }
    seen.push(normalized)
    var text: string = ""
    match fs.read(normalized) {
        ok(contents) => { text = contents }
        err(error) => {
            return err(
                "cannot read csrc input {normalized}: {error.msg}",
                "io")
        }
    }
    var key: string = "|{normalized}|{text}"
    for line: string in text.lines() {
        let include: string = csrc_quoted_include(line)
        if include == "" { continue }
        let dependency: string =
            csrc_normalize_path(
                path.join(path.parent(normalized), include))
        if File.exists(dependency) {
            key = "{key}{csrc_dependency_key(dependency, seen)?}"
        }
    }
    return ok(key)
}

fn csrc_inputs_key(sources: List<string>) -> Result<string> {
    var seen: List<string> = []
    var key: string = ""
    for source: string in sources {
        key = "{key}{csrc_dependency_key(source, seen)?}"
    }
    return ok(key)
}

fn csrc_compiler_identity(compiler: string) -> string {
    let command: process.Command = new process.Command(compiler)
    command.arg("--version")
    match command.run() {
        ok(done) => {
            return "{compiler}|{done.status}|{done.stdout_text()}|{done.stderr_text()}"
        }
        err(_) => { return compiler }
    }
}

fn csrc_cache_dir() -> string {
    return path.join(
        path.join(beans_home(), "cache"), "csrc")
}

fn csrc_host_compiler() -> string {
    match os.env("BEANS_CC") {
        some(value) => {
            if value != "" { return value }
        }
        none => {}
    }
    return "clang"
}

// Write-to-staging-and-rename, so two concurrent cold-cache builds never
// interleave writes into one file a loader is about to read.
fn csrc_staging_name(target: string) -> string {
    match random.bytes(8) {
        ok(seed) => {
            return "{target}.{seed.get_u64(0)}"
        }
        err(_) => {
            return "{target}.{time.wall_millis()}"
        }
    }
}

fn csrc_publish(staging: string, target: string) {
    match File.rename(staging, target) {
        ok(_) => {}
        err(_) => {
            // a concurrent build already published the same content
            match File.remove(staging) {
                ok(_) => {}
                err(_) => {}
            }
        }
    }
}

// One host shared library holding every selected csrc source, for the
// interpreter. Cached by content hash beside the package cache, so a
// dependency edit rebuilds and an unchanged tree loads instantly.
fn csrc_run_library(sources: List<string>,
                    os_name: string,
                    target_name: string) -> Result<string> {
    let compiler: string = csrc_host_compiler()
    let inputs: string = csrc_inputs_key(sources)?
    let key: string =
        "run|{target_name}|{csrc_compiler_identity(compiler)}|{inputs}"
    let extension: string =
        if os_name == "windows" {
            "dll"
        } else if os_name == "macos" {
            "dylib"
        } else {
            "so"
        }
    let cache: string = csrc_cache_dir()
    match Dir.create_all(cache) {
        ok(_) => {}
        err(error) => {
            return err(
                "cannot create csrc cache {cache}: {error.msg}",
                "io")
        }
    }
    let library: string =
        path.join(
            cache,
            "beans_csrc.{csrc_key_tag(key)}.{extension}")
    if File.exists(library) { return ok(library) }
    let staging: string = csrc_staging_name(library)
    let command: process.Command =
        new process.Command(compiler)
    command.arg("-O2")
    if os_name != "windows" {
        command.arg("-fPIC")
    }
    if os_name == "macos" {
        command.arg("-dynamiclib")
    } else {
        command.arg("-shared")
    }
    for source: string in sources {
        command.arg(source)
    }
    command.arg("-o")
    command.arg(staging)
    match command.run() {
        ok(done) => {
            if !done.succeeded() {
                var message: string =
                    done.stderr_text().trim()
                if message == "" {
                    message =
                        "Clang failed (exit {done.status})"
                }
                return err(message, "toolchain")
            }
        }
        err(error) => {
            return err(
                "cannot start Clang to build csrc sources: {error.msg} — csrc packages need a C compiler even under 'beansc run'",
                "toolchain")
        }
    }
    csrc_publish(staging, library)
    if !File.exists(library) {
        return err(
            "csrc library did not appear at {library}", "io")
    }
    return ok(library)
}
