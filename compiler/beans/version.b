// Generated from compiler/version.h by tools/gen_version_b.sh. Do not edit.
//
// Stage 0 includes compiler/version.h; the self-hosted compiler cannot include
// a C++ header, so it reads the same numbers from here. Bump compiler/version.h
// and rebuild — test/version.sh refuses a stale copy.

fn compiler_version() -> string {
    return "0.1.0"
}

fn compiler_banner() -> string {
    return "beansc 0.1.0 (language 1.0, runtime ABI 4)"
}
