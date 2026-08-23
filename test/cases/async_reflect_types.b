import std.io
import std.reflect

struct Callables {
    pub local: async fn(int) -> int
    pub remote: send async fn() -> int
}

fn transform(
    callback: async fn(int) -> int) -> send async fn() -> int {
    return send async fn() -> int { return 9 }
}

fn show(type: reflect.Type) {
    io.println("{type.qualified_name()}:{type.kind()}")
}

fn main() {
    show(type_of(fn() -> int))
    show(type_of(send fn() -> int))
    show(type_of(async fn() -> int))
    show(type_of(send async fn() -> int))

    let owner: reflect.Type = type_of(Callables)
    show(owner.field("local").expect("local").type())
    show(owner.field("remote").expect("remote").type())

    let function: reflect.Function =
        reflect.find_function("main.transform").expect("transform")
    show(function.parameters()[0].type())
    show(function.result_type())
}
