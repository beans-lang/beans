// A package the module root never imports.

package deep

/// A counter nothing above it reaches.
pub partial class Counter {
    /// Visible to anyone.
    pub total: int
    /// Visible only inside Counter.
    priv seen: int

    pub fn init(total: int) {
        self.total = total
        self.seen = 0
    }

    /// One more.
    pub fn bump() -> int {
        self.seen = self.seen + 1
        return self.total + self.seen
    }
}

/// Twice the value.
pub fn doubled(value: int) -> int {
    return value * 2
}

pub fn local_use() -> int {
    return doubled(21)
}
