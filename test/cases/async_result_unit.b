import std.async as aio
import std.io
import std.thread

fn noop() {}

fn okay() -> Result<unit> { return ok(noop()) }
fn failed() -> Result<unit> { return err("unit failed") }

fn propagate(value: Result<unit>) -> Result<int> {
    value?
    return ok(7)
}

async fn main() {
    let worker: Thread<unit> = thread.spawn_async(
        send async fn() -> unit { await aio.yield_now() })
    let joined: Result<unit> = await worker.join_async()
    io.println("join {joined.is_ok()}")
    joined.expect("join unit")

    let good: Result<unit> = okay()
    good.expect("expected unit")
    good.or(noop())
    io.println("equal {good == okay()} {good == failed()}")

    match good {
        ok(value) => {
            let used: unit = value
            io.println("match ok")
        }
        err(_) => { io.println("match err") }
    }
    io.println("try {propagate(okay()).or(0)}")
    io.println("try error {propagate(failed()).is_ok()}")
}
