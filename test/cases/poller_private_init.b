// The three descriptors are an implementation detail; fabricating a poller from raw
// numbers would let a caller close one behind the handle's back.
import std.poll
fn main() {
    let fake: poll.Poller = new poll.Poller(1, 2, 3)
}
