// A poller owns three descriptors, so a second owner would close them twice.
import std.poll
fn go() -> Result<int> {
    let watch: poll.Poller = poll.Poller.open()?
    let alias: poll.Poller = watch
    return ok(alias.wait(1, 0)?.len())
}
fn main() { let x: Result<int> = go() }
