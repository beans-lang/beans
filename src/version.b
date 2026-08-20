// Generated from VERSION by tools/gen_version_b.sh. Do not edit.
//
// The compiler reads its own version from here because it cannot read VERSION
// while compiling itself. Bump VERSION and rebuild — test/version.sh refuses a
// stale copy.

package main

fn compiler_version() -> string {
    return "0.1.25"
}

fn compiler_banner() -> string {
    return "beansc 0.1.25 (language 1.0, runtime ABI 7)"
}
