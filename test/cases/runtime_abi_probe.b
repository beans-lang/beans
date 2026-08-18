// Exercises a spread of fallible/optional runtime builtins so their calls and
// declarations appear in the emitted IR: to_int (Result, {i64,ptr}), find
// (Option, {i64,i64}), map get and index (beans_map_get_raw). test/runtime_abi.sh
// asserts none of these cross the C boundary as a struct return or through sret.
// Deliberately no `extern "C"` — user aggregate ABI is a separate, legitimate use
// of sret, and this program keeps the runtime-builtin boundary in isolation.
import std.io

fn main() {
    match "42".to_int() {
        ok(n) => io.println("{n}"),
        err(e) => io.println("bad int: {e.msg}"),
    }
    match "hello".find("ll") {
        some(i) => io.println("found at {i}"),
        none => io.println("not found"),
    }
    // int keys take the beans_map_get_raw path (the {i64,i64} Option shape)
    var scores: Map<int, int> = {1: 10, 2: 20}
    match scores.get(1) {
        some(v) => io.println("1 = {v}"),
        none => io.println("no 1"),
    }
    let direct: int = scores[2]
    io.println("2 = {direct}")
}
