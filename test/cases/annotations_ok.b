import std.io

@target(value: ["type", "function", "method", "field", "variant", "parameter", "local", "c_global", "annotation"])
@retention(value: "tool")
annotation mark {
    value: string = "plain"
    flags: List<string> = []
}

@target(value: ["function"])
@retention(value: "source")
@repeatable
annotation generated {
    value: bool
}

@mark(value: "schema")
annotation described {}

@mark(value: "record", flags: ["one", "two"])
class Crate {
    @mark(value: "field")
    value: int = 1

    @mark(value: "method")
    fn read(@mark(value: "parameter") amount: int) -> int {
        @mark(value: "local")
        let result: int = self.value + amount
        return result
    }
}

@mark(value: "enum")
enum Choice {
    @mark(value: "variant")
    yes(@mark(value: "payload") value: int)
    no
}

@mark(value: "global")
extern "C" let external_count: int

@mark(value: "function")
@generated(value: true)
@generated(value: false)
fn main() {
    let box: Crate = new Crate()
    io.println(box.read(1))
}
