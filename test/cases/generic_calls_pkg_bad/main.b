// Value-position package lookups that must fail, with the same messages
// the call path produces.
package main
import std.io
import app.tools

fn main() {
    let f: fn(int) -> int = tools.hidden
    let g: fn(int) -> int = tools.missing
    io.println(f(1) + g(2))
}
