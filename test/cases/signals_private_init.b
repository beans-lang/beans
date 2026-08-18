// Fabricating a signal source from a raw descriptor would let a caller unblock signals
// the real source is still watching.
import std.signal
fn main() {
    let fake: signal.Signals = new signal.Signals(1, new Bytes(0))
}
