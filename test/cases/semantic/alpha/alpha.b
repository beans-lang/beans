// One of two packages that both declare a `Shape` and a `size` method, so a
// query that answers by name instead of by symbol gets caught here.
package alpha

/// A shape measured in alpha units.
pub class Shape {
    /// How wide the alpha shape is.
    pub width: int

    pub fn init(width: int) {
        self.width = width
    }

    /// Alpha's own size, unrelated to beta's.
    pub fn size() -> int {
        return self.width
    }
}

pub fn scale(value: int) -> int {
    return value * 2
}
