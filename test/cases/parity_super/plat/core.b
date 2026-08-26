// `super.init(...)` passed an argument the initializer sinks, but the pass
// that settles ownership for a sinking parameter only ever looked at `new`.
// The caller kept its reference and released after the call while the
// initializer had stored without retaining, so the field was left pointing at
// freed memory. Reading it worked or crashed depending on whether anything
// had reused the block yet, which is why moving the call changed the outcome.
//
// It needs a library package to show: same-package construction takes a
// different path.
package plat

pub interface Atlas {
    fn tag() -> string
}

pub class FakeAtlas implements Atlas {
    pub fn init() {}

    pub fn tag() -> string { return "atlas" }
}

pub class Named {
    pub label: string

    pub fn init(label: string) { self.label = label }

    pub fn name_of() -> string { return self.label }
}

// an interface-typed field, reached through the base
pub class BaseWindow {
    pub the_atlas: Atlas

    pub fn init(a: Atlas) { self.the_atlas = a }

    pub fn kind_name() -> string { return "base" }
}

pub class Window extends BaseWindow {
    pub fn init() { super.init(new FakeAtlas()) }
}

// and a class-typed one, which had the same fault
pub class BaseHolder {
    pub held: Named

    pub fn init(n: Named) { self.held = n }

    pub fn kind_name() -> string { return "holder" }
}

pub class Holder extends BaseHolder {
    pub fn init() { super.init(new Named("held")) }
}
