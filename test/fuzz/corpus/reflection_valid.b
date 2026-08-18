import std.reflect

@target(value: ["type", "field", "method", "parameter"])
@retention(value: "runtime")
annotation fuzz_reflect {
    name: string = "seed"
}

@fuzz_reflect()
pub struct SeedRecord {
    @fuzz_reflect(name: "field")
    pub text: string
    pub value: int
}

pub fn seed_call(value: int) -> int { return value }

fn main() {
    let descriptor: reflect.Type = type_of(SeedRecord)
    let initializer: reflect.Initializer =
        descriptor.initializer().expect("initializer")
    let made: reflect.Value = initializer.call([
        reflect.value("seed"), reflect.value(1)]).expect("record")
    let record: SeedRecord = (made as? SeedRecord).expect("SeedRecord")
    let field: reflect.Field = descriptor.field("value").expect("value")
    let function: reflect.Function =
        reflect.find_function("main.seed_call").expect("seed_call")
}
