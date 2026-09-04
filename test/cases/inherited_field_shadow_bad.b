// #95: a subclass cannot redeclare a field name it inherits. The tree
// interpreter keyed object storage by field name and gave the two
// declarations one slot; a native build laid each out at its own offset and
// gave them two. `check` accepted the shape and the backends disagreed about
// the object. The redeclaration is refused here so one name means one slot.
//
// Covered shapes: a direct parent shadow, a grandparent shadow reached
// through a middle class that does not itself declare the name, and two
// shadowed fields in one subclass.
class Grand {
    x: int = 0
    y: int = 0
}

class Middle extends Grand {
    z: int = 0
}

class Sub extends Middle {
    x: int = 0
    z: int = 0
}

fn main() {}
