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

fn csrc_key_hash(key: string) -> int {
    var hash: int = 0
    for index: int in 0..key.len() {
        hash =
            (hash * 131 + key.byte_at(index)) %
            2147483647
    }
    return hash
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
                    os_name: string) -> Result<string> {
    var key: string = "run|{os_name}"
    for source: string in sources {
        match fs.read(source) {
            ok(text) => {
                key = "{key}|{source}|{text}"
            }
            err(error) => {
                return err(
                    "cannot read csrc file {source}: {error.msg}",
                    "io")
            }
        }
    }
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
            "beans_csrc.{csrc_key_hash(key)}.{extension}")
    if File.exists(library) { return ok(library) }
    let staging: string = csrc_staging_name(library)
    let command: process.Command =
        new process.Command(csrc_host_compiler())
    command.arg("-O2")
    command.arg("-fPIC")
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
