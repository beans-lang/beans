// #94: the checker proves an object is fully built. Each class here breaks one
// clause of that proof, and check refuses it — every one of these once passed
// check and then panicked interpreted while a native build read a raw slot.

// a field construction never assigns
class NeverAssigned {
    a: int = 1
    b: string
    fn init() {
        self.a = 2
    }
}

// a pointer-shaped field never assigned — the case a native build answered
// none for while the interpreter panicked
class SlotUnset {
    p: Option<int>
    fn init() {}
}

// a method call on self before every field is assigned
class CallEarly {
    b: string
    fn init() {
        self.speak()
        self.b = "x"
    }
    fn speak() {}
}

// a field read before it is assigned
class ReadEarly {
    a: int
    b: int
    fn init() {
        self.a = self.b
        self.b = 1
    }
}

// a field assigned on only one arm of a branch
class PartialBranch {
    a: int
    fn init(x: int) {
        if x > 0 {
            self.a = 1
        }
    }
}

// a field assigned only inside a loop, which may run zero times
class LoopOnly {
    a: int
    fn init(xs: List<int>) {
        for x: int in xs {
            self.a = x
        }
    }
}

// a required field with no init to assign it
class NoInit {
    x: int
}

// a base class that declares an init, and a subclass that never calls super.init
class NeedsSuperBase {
    z: int
    fn init() {
        self.z = 0
    }
}
class ForgotSuper extends NeedsSuperBase {
    y: int
    fn init() {
        self.y = 1
    }
}

// super.init called before the subclass assigns its own fields
class SuperTooEarly extends NeedsSuperBase {
    w: int
    fn init() {
        super.init()
        self.w = 1
    }
}

// super.init inside a branch, not a top-level statement
class SuperNested extends NeedsSuperBase {
    v: int
    fn init(flag: bool) {
        self.v = 1
        if flag {
            super.init()
        }
    }
}

// super.init more than once
class SuperTwice extends NeedsSuperBase {
    u: int
    fn init() {
        self.u = 1
        super.init()
        super.init()
    }
}

// interpolation reading a field before it is assigned
class InterpEarly {
    a: int
    b: int
    fn init() {
        let s: string = "b is {self.b}"
        self.a = s.len()
        self.b = 2
    }
}
