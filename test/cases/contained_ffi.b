// A contained call whose failure has to cross a C frame (issue #145).
//
// beans_test_call_once is a C function in test/fixtures/c_callback_helper.c
// that calls the Beans closure it is handed. A panic inside that closure has
// to unwind the C frame between it and the catch frame, and the catch frame
// has to answer with a Result all the same. That works because every frame on
// the path carries an unwind table: the driver passes -funwind-tables for a
// build that can unwind, and this test's helper is built by clang, which puts
// one on every C frame on the targets the unwind supports.
//
// The second case is the same call succeeding, so the golden also pins that
// nothing about the C hop changes on the path where nothing fails.
import std.io

extern "C" fn beans_test_call_once(callback: fn() -> i32) -> i32

class Res {
    pub tag: string
    fn init(tag: string) { self.tag = tag }
    fn deinit() { io.println("  drop {self.tag}") }
}

fn across_c(fail: bool) -> int {
    let held: Res = new Res("across-c")
    defer io.println("  across-c defer")
    unsafe {
        let answer: i32 =
            beans_test_call_once(
                fn() -> i32 {
                    if fail { panic("callback refused") }
                    return 21
                })
        return (answer as int) * 2
    }
}

fn main() {
    io.println("across a C frame, no failure:")
    match contained across_c(false) {
        ok(v) => { io.println("  ok {v}") }
        err(p) => { io.println("  err {p.kind}") }
    }
    io.println("across a C frame, panicking:")
    match contained across_c(true) {
        ok(v) => { io.println("  unexpected ok {v}") }
        err(p) => { io.println("  caught {p.kind}: {p.msg}") }
    }
    io.println("done")
}
