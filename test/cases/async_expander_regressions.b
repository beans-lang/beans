import std.async as aio
import std.io

class Chain {
    fn init() {}

    async fn step(index: int) -> Result<bool> {
        if index > 0 { return ok(true) }
        let next: async fn() -> Result<bool> =
            async fn() -> Result<bool> {
                return await self.step(index + 1)
            }
        return await next()
    }
}

async fn recurse(index: int) -> Result<int> {
    if index > 0 { return ok(index) }
    let next: async fn() -> Result<int> =
        async fn() -> Result<int> {
            return await recurse(index + 1)
        }
    return await next()
}

fn mark(value: int) -> int {
    io.println("mark {value}")
    return value
}

fn checked() -> Result<int> {
    io.println("checked")
    return ok(2)
}

fn add(left: int, right: int) -> int { return left + right }
fn add3(first: int, second: int, third: int) -> int {
    return first + second + third
}

fn rejected() -> Result<int> {
    io.println("rejected")
    return err("stop")
}

async fn propagate() -> Result<int> {
    let total: int = add(mark(1), checked()?)
    await aio.yield_now()
    return ok(total)
}

async fn propagate_error() -> Result<int> {
    // mark(6) must not run after the middle argument propagates its error.
    return ok(add3(mark(4), rejected()?, mark(6)))
}

async fn stop_before_await() -> Result<int> {
    let value: int = rejected()?
    await aio.yield_now()
    io.println("result resumed {value}")
    return ok(value)
}

fn optional(keep: bool) -> Option<int> {
    if keep { return some(7) }
    return none
}

async fn propagate_option(keep: bool) -> Option<int> {
    let value: int = optional(keep)?
    await aio.yield_now()
    return some(value + 1)
}

async fn branch_local() -> int {
    match some(1) {
        some(value) => {
            var total: int = value
            await aio.yield_now()
            total += 1
            return total
        }
        none => { return 0 }
    }
}

async fn loop_local() -> int {
    for true {
        var count: int = 0
        await aio.yield_now()
        count += 1
        return count
    }
    return 0
}

fn one() -> int { return 1 }

async fn run_job<T implements Send>(
        move job: send fn() -> T) -> Result<T> {
    let finished: Channel<T> = new Channel(1)
    let work: send fn() = fn() move(job) {
        finished.send(job())
    }
    await aio.yield_now()
    work()
    return ok(finished.receive().expect("result"))
}

async fn main() {
    let chain: Chain = new Chain()
    let method_result: bool = (await chain.step(0)).or(false)
    io.println("method {method_result}")
    let free_result: int = (await recurse(0)).or(0)
    io.println("free {free_result}")
    let try_result: int = (await propagate()).or(0)
    io.println("try {try_result}")
    let stopped: bool = (await propagate_error()).is_ok()
    io.println("stopped {stopped}")
    let before_await: bool = (await stop_before_await()).is_ok()
    io.println("before await {before_await}")
    let option_some: int = (await propagate_option(true)).or(0)
    let option_none: bool = (await propagate_option(false)).is_some()
    io.println("option {option_some} {option_none}")
    let branch_result: int = await branch_local()
    let loop_result: int = await loop_local()
    io.println("locals {branch_result} {loop_result}")
    let job: send fn() -> int = one
    let capture_result: int = (await run_job(move job)).or(0)
    io.println("capture {capture_result}")
}
