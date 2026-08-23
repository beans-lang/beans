import std.async as aio
import std.thread
import std.time

async fn main() {
    let channel: Channel<int> = new Channel<int>(1)
    channel.send(1)
    let closer: Thread<int> = thread.spawn(fn() -> int {
        time.sleep_millis(10)
        channel.close()
        return 0
    })
    await channel.send_async(2)
}
