// A library's own startup, with no `main` to run it.
//
// Three things happen before a program's first line: the reflection registry
// is filled, static fields take their declared values, and singletons are
// built. All three used to be emitted into `main`'s entry block.
//
// A **library** has no `main`. Two of the three survived that anyway, because
// each carries its own guard: the first read of a static field or a singleton
// runs its initializer. **Reflection has no such guard and cannot have one** —
// nothing reads "the registry", it is read by name, and a name that was never
// registered is indistinguishable from a name that does not exist. So a
// module built with `--emit shared` answered "no such type" for every class it
// defines, with no diagnostic anywhere, and the symptom was a framework that
// could not activate a class it could see.
//
// `@beans_module_start` is where the three live now, and a host calls it once
// after instantiating. This file is what proves it ran; the fixture beside it
// also proves what happens when it does not.
import std.reflect

/// Retained at run time, or reflection would not carry it at all — which
/// would make this half of the test pass for the wrong reason.
@retention(value: "runtime")
pub annotation marked {
    note: string = ""
}

@marked(note: "on the class")
pub class Thing {
    pub label: string = "made"
    pub fn init() {}
}

pub singleton class Counter {
    pub started: int = 7
    fn init() {}
}

pub class Settings {
    /// A static field: its initializer is part of the module's startup, and a
    /// library that never ran that startup read the zero underneath it.
    pub static width: int = 320
    pub fn init() {}
}

/// 1 when reflection can find the class, 2 when it can also call its
/// initializer, 4 when the annotation is there, 8 when the singleton ran its
/// initializer, 16 when a static field has its declared value.
///
/// One number rather than five exports: a host that got 0 from any of them
/// would have to ask why, and a bitmask says which half is missing.
pub extern "C" fn probe() -> i32 as "beans_library_reflect" {
    var found: int = 0
    // Searched rather than looked up by name: a bare file's qualified names
    // depend on how it was compiled, and this is a question about whether the
    // registry has anything in it at all.
    var wanted: Option<reflect.Type> = none
    for described: reflect.Type in reflect.types() {
        if described.name() == "Thing" { wanted = some(described) }
    }
    match wanted {
        none => {}
        some(described) => {
            found = found | 1
            match described.initializer() {
                none => {}
                some(initializer) => {
                    match initializer.call([]) {
                        // The value that comes back is a boxed one, which is
                        // the only source `as?` may narrow from — and
                        // narrowing it is the point: a class the registry
                        // never heard of has no initializer to call at all.
                        ok(value) => {
                            match value as? Thing {
                                some(thing) => { if thing.label == "made" { found = found | 2 } }
                                none => {}
                            }
                        }
                        err(problem) => {}
                    }
                }
            }
            for annotation: reflect.Annotation in described.annotations() {
                if annotation.name() == "marked" { found = found | 4 }
            }
        }
    }
    if Counter.instance.started == 7 { found = found | 8 }
    if Settings.width == 320 { found = found | 16 }
    return found as i32
}
