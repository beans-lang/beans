// Assigning to a field that does not exist. The checker records the same
// error the read path does, but the guard beside the report tested one list
// and the code below it indexed another, so the compiler died on an
// unguarded index before it could print anything.
//
// A crash is bad; this one was worse than bad. It landed before main and
// before any output, so it read as a static-init fault in an imported
// package, and the position it named was inside the compiler's own source.
// Someone spent forty minutes bisecting a one-word typo.
//
// Reading `b.h` was always reported properly, which is the contrast that
// gave the diagnosis away.
struct Box2 {
    w: f32 = 0.0
}

class Holder {
    pub kept: int = 0

    fn init() {}
}

fn main() {
    var b: Box2 = Box2 { w: 1.0 }
    b.h = 3.0
    b.d += 1.0

    let holder: Holder = new Holder()
    holder.missing = 2
}
