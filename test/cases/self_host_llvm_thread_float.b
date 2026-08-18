// Thread results ride the runtime's i64 slot, but the closure's
// real signature returns the payload type: passing the raw fn to
// beans_thread_spawn let a double come back in the wrong register
// class, and join printed 1.578648823e-313 where the interpreter
// said 3.5. Every spawn now goes through a thunk that widens the
// result into the slot — bitcast for floats, sign-aware extends
// for narrow ints, the address itself for references.
import std.io
import std.thread

fn main() {
    let wide: Thread<float> = thread.spawn(fn() -> float {
        return 3.5
    })
    let wide_got: float = wide.join()
    io.println("{wide_got}")

    let narrow: Thread<f32> = thread.spawn(fn() -> f32 {
        return 1.25 as f32
    })
    let narrow_got: f32 = narrow.join()
    io.println("{narrow_got}")

    let signed: Thread<i8> = thread.spawn(fn() -> i8 {
        return -7 as i8
    })
    let signed_got: i8 = signed.join()
    io.println("{signed_got}")

    let big: Thread<u64> = thread.spawn(fn() -> u64 {
        return 5000000000 as u64
    })
    let big_got: u64 = big.join()
    io.println("{big_got}")

    let flag: Thread<bool> = thread.spawn(fn() -> bool {
        return true
    })
    let flag_got: bool = flag.join()
    io.println("{flag_got}")

    let text: Thread<string> = thread.spawn(fn() -> string {
        return "beans"
    })
    let text_got: string = text.join()
    io.println("{text_got}")
}
