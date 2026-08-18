import std.io

@runtime_hook(before: "async_before", after_return: "async_after")
@target(value: ["function"])
annotation async_trace {
    phase: string
}

fn async_before(target: string, phase: string) {
    io.println("before:{phase}")
}

fn async_after(target: string, phase: string) {
    io.println("after:{phase}")
}

@async_trace(phase: "pre-await")
fn before_await(value: int) -> int {
    io.println("body:pre-await")
    return value + 1
}

@async_trace(phase: "post-await")
fn after_await(value: int) -> int {
    io.println("body:post-await")
    return value * 2
}

async fn pass(value: int) -> int {
    return value
}

async fn flow() -> int {
    let first: int = before_await(3)
    let resumed: int = await pass(first + 1)
    return after_await(resumed)
}

async fn main() {
    let result: int = await flow()
    io.println("result {result}")
}
