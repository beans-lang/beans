// The second `Shape`. Same short name, different package, different members.
package beta

pub class Shape {
    pub height: int

    pub fn init(height: int) {
        self.height = height
    }

    pub fn size() -> int {
        return self.height
    }

    // Only beta has this one.
    pub fn stretch() -> int {
        return self.height * 3
    }
}

pub fn scale(value: int) -> int {
    return value + 1
}
