/*
Does AddressSanitizer reach the code the compiler emitted? (issue #168)

`BEANS_SANITIZE` used to reach only the clang command line, and an LLVM
sanitizer pass looks inside a function only when that function carries its
attribute. So a sanitized build instrumented beans_rt.c and the bridges and
walked straight past every line beansc generated: reading far off the end of a
heap block was silent, and `make test-sanitize` said "ok".

Every shape below is a load or a store the emitter wrote. ASan can only see
them if the definition around them says `sanitize_address`, so a run of this
program is a direct answer to "is the generated code instrumented", not to "is
the sanitizer runtime linked". `doublefree` is the other question, and the
opposite one: ASan's allocator catches that with nothing instrumented at all,
so it says the runtime is present even when nothing else is.

One process reports one error — ASan stops at the first — so the shape is a
command-line argument and test/sanitize.sh builds this once and runs it six
times.
*/

package main

import std.io
import std.os

fn main() {
    var mode: string = "clean"
    let arguments: List<string> = os.args()
    if arguments.len() != 0 {
        mode = arguments[0]
    }
    unsafe {
        // Thirty-two bytes, four elements, all four written and read back so
        // the block is genuinely live and genuinely in bounds first. A probe
        // that only ever goes out of bounds cannot tell a sanitizer that
        // works from a build that is broken.
        let block: RawPtr<i64> = RawPtr.alloc(4)
        for index: int in 0..4 {
            block.offset(index).write(index + 1)
        }
        var total: i64 = 0
        for index: int in 0..4 {
            total += block.offset(index).read()
        }
        io.println("in bounds {total}")
        var freed: bool = false
        if mode == "read" {
            // One element past the end. The issue was filed with a read 32
            // KiB past the block, and that is the same instrumented load —
            // but where an address that far away lands is the allocator's
            // business, and inside another live block ASan would say nothing.
            // One element past is a redzone on every host, so the gate asks
            // about the instrumentation and not about the heap's layout.
            let stolen: i64 = block.offset(4).read()
            io.println("read past the end and lived: {stolen}")
        } else if mode == "write" {
            // A store, not a load: the two are instrumented separately.
            block.offset(4).write(0 - 1)
            io.println("wrote past the end and lived")
        } else if mode == "uaf" {
            let dangling: RawPtr<i64> =
                RawPtr.from_address(block.address())
            block.free()
            freed = true
            let stolen: i64 = dangling.read()
            io.println("read freed memory and lived: {stolen}")
        } else if mode == "doublefree" {
            block.free()
            block.free()
            freed = true
            io.println("freed the same block twice and lived")
        }
        if !freed {
            block.free()
        }
        io.println("done {mode}")
    }
}
