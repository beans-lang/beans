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

unique class Handle {
    fn init() {}
    fn tag() -> int { return 9 }
}

fn open_handle() -> Result<Handle> { return ok(new Handle()) }

async fn held_across_await() -> Result<bool> {
    let handle: Handle = open_handle()?
    await aio.yield_now()
    let tag: int = handle.tag()
    return ok(tag == 9)
}

async fn closed_before_await() -> Result<bool> {
    let handle: Handle = open_handle()?
    let tag: int = handle.tag()
    await aio.yield_now()
    return ok(tag == 9)
}

enum Feed {
    body(value: Bytes)
    done
}

async fn consume_feed(event: Feed) -> Result<int> {
    match event {
        body(piece) => { return ok(piece.len()) }
        done => {
            await aio.yield_now()
            return ok(0)
        }
    }
}

async fn keep_across_split(flag: bool) -> int {
    await aio.yield_now()
    let kept: int = 41
    if flag { return 0 }
    return kept + 1
}

fn guard(fine: bool) -> Result<bool> {
    if fine { return ok(true) }
    return err("guard refused", "guard")
}

async fn consume_guarded(event: Feed, limit: int) -> Result<int> {
    match event {
        body(piece) => {
            let grown: int = piece.len()
            if grown > limit {
                guard(false)?
                return ok(0 - 1)
            }
            guard(true)?
            return ok(grown)
        }
        done => {
            await aio.yield_now()
            return ok(0)
        }
    }
}

async fn method_kept() -> string {
    let requested: string = "GET"
    for value: int in [1] {
        if value == 1 {
            await aio.yield_now()
        }
    }
    return "method {requested}"
}

fn problem(code: int) -> Result<int> {
    if code > 0 { return err("boom", "shadow") }
    return ok(code)
}

async fn shadow_error() -> Result<bool> {
    let called: Result<int> = problem(3)
    await aio.yield_now()
    match called {
        ok(value) => { return ok(value > 0) }
        err(problem) => {
            return err("call failed: {problem.msg}", "shadow")
        }
    }
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
    let held: bool = (await held_across_await()).or(false)
    let closed: bool = (await closed_before_await()).or(false)
    io.println("unique {held} {closed}")
    let fed: int = (await consume_feed(
        Feed.body(Bytes.from("body")))).or(0)
    let drained: int = (await consume_feed(Feed.done)).or(9)
    io.println("enum {fed} {drained}")
    let kept: string = await method_kept()
    io.println("{kept}")
    let across: int = await keep_across_split(false)
    let cut: int = await keep_across_split(true)
    io.println("split {across} {cut}")
    let fits: int = (await consume_guarded(
        Feed.body(Bytes.from("body")), 10)).or(0 - 9)
    let refused: bool = (await consume_guarded(
        Feed.body(Bytes.from("body")), 2)).is_ok()
    io.println("guarded {fits} {refused}")
    var shadow_text: string = "unset"
    match await shadow_error() {
        ok(fine) => { shadow_text = "ok {fine}" }
        err(reported) => { shadow_text = reported.msg }
    }
    io.println("shadow {shadow_text}")
}
