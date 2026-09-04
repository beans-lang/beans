// A generic base whose receiver crosses a package boundary. `shelf_tag` and
// `shelf_mark` call methods on a `Shelf<int>` written here, but the object can
// be a subclass declared in another package. `tag` is public and not
// overridden, so it runs direct — and its `self.hidden()` must reach shapes'
// own package-private `hidden`, not a same-named one a consumer package
// declares. `mark` is public and overridden across the boundary, so it reads
// the descriptor. The native emitter used to call the base body outright for
// both and segfaulted on the first.
package shapes

pub class Shelf<T> {
    priv held: T
    priv n: int

    pub fn init(held: T, n: int) { self.held = held; self.n = n }

    // package-private to shapes: a consumer's method of this name is a
    // separate method in a different slot, never a replacement
    fn hidden() -> string { return "shelf{self.n}" }

    pub fn tag() -> string { return "tag:{self.hidden()}" }

    pub fn mark() -> string { return "base" }

    pub fn held_is() -> T { return self.held }
}

pub fn shelf_tag(value: Shelf<int>) -> string { return value.tag() }
pub fn shelf_mark(value: Shelf<int>) -> string { return value.mark() }
