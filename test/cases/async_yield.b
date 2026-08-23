import std.async as aio
import std.io

async fn child() {
    io.println("child before")
    await aio.yield_now()
    io.println("child after")
}

async fn main() {
    async let running: unit = child()
    await aio.yield_now()
    io.println("parent")
    await running
}
