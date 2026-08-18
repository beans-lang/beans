// Every way a partial class can be written wrong, in one file so the
// diagnostics can be asserted together.

// Two parts both carrying a header: there would be no single answer to
// what the class extends.
partial class TwoHeaders extends Base { }
partial class TwoHeaders implements Named { }

// Generic parameters are part of the header, so declaring them twice is
// the same mistake.
partial class TwoGenerics<T> { a: List<T> }
partial class TwoGenerics<T> { b: List<T> }

// So are modifiers.
pub partial class TwoModifiers { x: int }
pub partial class TwoModifiers { y: int }

// A member declared in two parts is still a member declared twice.
partial class Repeated { fn go() {} }
partial class Repeated { fn go() {} }

// A plain class does not silently join a partial one. Someone reusing a
// name by accident must still hear about it.
partial class NotPartial { fn a() {} }
class NotPartial { fn b() {} }

class Base {}
interface Named { fn label() -> string }

fn main() {}
