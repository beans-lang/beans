import std.async as aio
import std.reflect

pub async fn explode() -> int {
    await aio.yield_now()
    panic("async reflected target panic")
    return 0
}

async fn main() {
    let function: reflect.Function =
        reflect.find_function("main.explode").expect("explode")
    let result: reflect.Value =
        (await function.call_async([])).expect("reflection start")
}
