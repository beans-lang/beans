// A signal source owns a descriptor and a signal mask, so a second owner would unblock
// and close them twice.
import std.signal
fn go() -> Result<int> {
    let want: int = signal.Signal.user1()?
    let watch: signal.Signals = signal.Signals.watch_signal(want)?
    let alias: signal.Signals = watch
    return ok(alias.poll_handle())
}
fn main() { let x: Result<int> = go() }
