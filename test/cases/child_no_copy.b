// A Child owns a pid and three pipes, so a second owner would reap and close them twice.
import std.process
fn go() -> Result<int> {
    var cmd: process.Command = new process.Command("/bin/sh")
    let child: process.Child = cmd.start()?
    let alias: process.Child = child
    return ok(alias.id())
}
fn main() { let x: Result<int> = go() }
