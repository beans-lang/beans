import std.io
import std.reflect

enum Level {
    low
    high
}

@target(value: ["annotation"])
@retention(value: "runtime")
annotation schema {
    label: string = "schema"
}

@schema()
@target(value: ["type", "function", "method", "field", "variant", "parameter"])
@retention(value: "runtime")
@repeatable
annotation note {
    text: string
    enabled: bool = true
    codes: List<int>
    level: Level
}

@note(text: "type-one", enabled: true, codes: [1, 2], level: Level.high)
@note(text: "type-two", enabled: false, codes: [], level: Level.low)
class Service {
    @note(text: "field", enabled: true, codes: [3], level: Level.low)
    pub value: int = 1

    @note(text: "method", enabled: true, codes: [], level: Level.high)
    pub fn read(
        @note(text: "parameter", enabled: false, codes: [4], level: Level.low)
        amount: int) -> int {
        return self.value + amount
    }
}

@note(text: "variant", enabled: true, codes: [5], level: Level.high)
enum Event {
    @note(text: "named", enabled: true, codes: [6], level: Level.low)
    named(
        @note(text: "payload", enabled: false, codes: [7], level: Level.high)
        value: int)
}

@note(text: "function", enabled: true, codes: [8, 9], level: Level.high)
pub fn work(
    @note(text: "function parameter", enabled: true, codes: [], level: Level.low)
    value: int) -> int {
    return value
}

fn print_note(annotation: reflect.Annotation) {
    io.println(annotation.name())
    let text: reflect.AnnotationArgument =
        annotation.argument("text").expect("text")
    io.println(text.value().as_string().expect("string"))
    let enabled: reflect.AnnotationArgument =
        annotation.argument("enabled").expect("enabled")
    io.println(enabled.value().as_bool().expect("bool"))
    let codes: List<reflect.AnnotationValue> =
        annotation.argument("codes").expect("codes").value().items()
    io.println(codes.len())
    for code: reflect.AnnotationValue in codes {
        io.println(code.as_int().expect("int"))
    }
    io.println(annotation.argument("level").expect("level").value().text())
}

fn main() {
    let service: reflect.Type = type_of(Service)
    io.println(service.annotations().len())
    print_note(service.annotations()[0])
    print_note(service.annotations()[1])
    print_note(service.field("value").expect("value").annotations()[0])
    let method: reflect.Method = service.method("read").expect("read")
    print_note(method.annotations()[0])
    print_note(method.parameters()[0].annotations()[0])

    let event: reflect.Variant =
        type_of(Event).variant("named").expect("named")
    print_note(event.annotations()[0])
    print_note(event.parameters()[0].annotations()[0])

    let function: reflect.Function =
        reflect.find_function("main.work").expect("work")
    print_note(function.annotations()[0])
    print_note(function.parameters()[0].annotations()[0])

    let note_type: reflect.AnnotationType =
        reflect.find_annotation_type("main.note").expect("note type")
    io.println("{note_type.name()}:{note_type.retention()}:{note_type.is_repeatable()}:{note_type.is_public()}")
    io.println("{note_type.targets().len()}:{note_type.targets()[0]}:{note_type.targets()[5]}")
    let enabled_default: bool = note_type.field("enabled").expect(
        "enabled").default_value().expect("default").as_bool().expect("bool")
    io.println("{note_type.fields().len()}:{enabled_default}")
    io.println(note_type.annotations()[0].name())
    io.println(service.annotations()[0].type().name())
}
