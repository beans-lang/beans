// Compiler-private bridge from an opaque reflected async call to Task.
// The loader includes this file only when std.reflect is present.

package async_rt

import std.reflection as rt

class ReflectCallGuard {
    handle: int
    dropper: fn(int) -> int

    fn init(handle: int, dropper: fn(int) -> int) {
        self.handle = handle
        self.dropper = dropper
    }

    fn poll() -> int { return rt.async_call_poll(self.handle) }

    fn finish() -> int {
        let result: int = rt.async_call_take(self.handle)
        self.handle = 0
        return result
    }

    fn cancel() {
        if self.handle == 0 { return }
        let drop: fn(int) -> int = self.dropper
        let dropped: int = drop(self.handle)
        self.handle = 0
    }

    fn deinit() { self.cancel() }
}

pub fn reflect_call_task(handle: int) -> Task<int> {
    let guard: ReflectCallGuard = new ReflectCallGuard(
        handle, fn(value: int) -> int {
            return rt.async_call_drop(value)
        })
    return new Task<int>(
        fn() -> int {
            return guard.poll()
        },
        fn() -> int {
            return guard.finish()
        },
        fn() {
            guard.cancel()
        })
}
