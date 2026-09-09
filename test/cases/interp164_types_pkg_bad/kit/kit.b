// The twin of interp_types_pkg/kit, holding the things a type name inside
// a string must be refused for naming: a class that is not pub, a
// function, and a module constant.
package kit

pub const SIZE: int = 3

pub fn helper(value: int) -> int { return value }

class Hidden {
    fn init() {}
}

pub class Widget {
    pub fn init() {}
    pub fn label() -> string { return "widget" }
}
