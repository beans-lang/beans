import std.io
import std.reflect

class Parent {
    pub fn label(move prefix: string) -> string {
        return prefix
    }

    fn hidden() -> int { return 1 }
}

class Child extends Parent {
    fn init(value: int) {}

    pub override fn label(move prefix: string) -> string {
        return prefix
    }

    pub static fn make() -> int { return 2 }
}

enum Event {
    idle
    named(name: string, count: int)
}

pub fn combine(left: int, inout right: int) -> int {
    return left + right
}

fn main() {
    let child: reflect.Type = type_of(Child)
    io.println(child.declared_methods().len())
    for method: reflect.Method in child.methods() {
        io.println("{method.declaring_type().name()}.{method.name()}:{method.result_type().name()}:{method.is_public()}:{method.is_static()}")
        for parameter: reflect.Parameter in method.parameters() {
            io.println("{parameter.name()}:{parameter.type().name()}:{parameter.passing()}")
        }
    }
    io.println(child.initializer().expect("init").parameters()[0].name())
    io.println(child.method("missing").is_none())

    let event: reflect.Type = type_of(Event)
    for variant: reflect.Variant in event.variants() {
        io.println("{variant.name()}:{variant.parameters().len()}")
        for parameter: reflect.Parameter in variant.parameters() {
            io.println("{parameter.name()}:{parameter.type().name()}")
        }
    }

    let combine_fn: reflect.Function =
        reflect.find_function("main.combine").expect("combine")
    io.println("{combine_fn.name()}:{combine_fn.result_type().name()}:{combine_fn.is_public()}")
    for parameter: reflect.Parameter in combine_fn.parameters() {
        io.println("{parameter.name()}:{parameter.type().name()}:{parameter.passing()}")
    }
    io.println(reflect.find_type("main.Child").expect("Child").name())
}
