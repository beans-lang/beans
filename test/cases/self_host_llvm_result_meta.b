// a Result box is {i64 tag, i64 slot}: the payload pointer sits at
// byte 8, which is pointer slot 8/stride — meta 17 on 8-byte
// pointers, 33 when pointers are four bytes. The suite greps both
// emissions; a hardcoded 17 once hid every 32-bit Result payload
// from the destructor walker, so ok(string) and err(...) leaked
// on those boards while 64-bit hosts stayed clean.
import std.io

fn check(text: string) -> Result<string, Error> {
    if text.len() == 0 {
        return err("empty")
    }
    return ok(text)
}

fn main() {
    match check("beans") {
        ok(value) => { io.println(value) }
        err(problem) => { io.println(problem.msg) }
    }
    match check("") {
        ok(value) => { io.println(value) }
        err(problem) => { io.println(problem.msg) }
    }
}
