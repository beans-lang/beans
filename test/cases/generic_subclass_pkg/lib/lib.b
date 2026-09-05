// The generic base lives in its own package. `weight` is public, so a
// subclass in another package answers the same selector and really is an
// override; `secret` is package-private, so its selector carries this package
// and no subclass elsewhere can replace it — its row on a foreign subclass's
// descriptor must still be the base's own body.
package lib

pub class Base<T> {
    pub v: T
    pub fn init(v: T) { self.v = v }
    pub fn kind() -> string { return "lib-base" }
    pub fn weight() -> int { return 1 }
    fn secret() -> int { return 7 }
}

pub class Plain {
    pub fn init() {}
    pub fn kind() -> string { return "lib-plain" }
}

// Reaches both on whatever concrete object stands behind a Base<int>
// receiver. `weight` is the call that used to compile direct to the base body
// because a generic subclass's override was never weighed; `secret` is the
// inherited row that must not be null on that same subclass.
pub fn weigh(b: Base<int>) -> int { return b.weight() }
pub fn confide(b: Base<int>) -> int { return b.secret() }
