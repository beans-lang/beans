@target(value: ["function", "wrong", "function"])
@retention(value: "binary")
annotation broken {
    callback: fn()
    value: string = runtime_value()
}

fn runtime_value() -> string {
    return "runtime"
}

fn main() {}
