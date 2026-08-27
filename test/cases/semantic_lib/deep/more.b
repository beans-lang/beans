// The other half of a partial class.
//
// A class written in two files is lowered once, into the part that carries
// the header — so nothing at all is registered at this file's own positions,
// and an editor asking about this file used to get no symbols, no hover and
// no navigation for anything in it.

package deep

partial class Counter {
    /// Half the value, written in the other file.
    pub fn halved() -> int {
        return self.total / 2
    }

    priv fn hidden() -> int {
        return self.seen
    }
}
