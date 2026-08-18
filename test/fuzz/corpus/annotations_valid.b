@target(value: ["annotation", "type", "function", "method", "field", "variant", "parameter", "local", "c_global"])
@retention(value: "tool")
@repeatable
annotation fuzz_probe {
    id: int
    note: string = "seed"
    tags: List<string> = []
}

@fuzz_probe(id: 0, tags: ["schema"])
@retention(value: "source")
annotation source_probe {}

@fuzz_probe(id: 1)
struct Item {
    @fuzz_probe(id: 2, note: "field")
    value: int
}

@fuzz_probe(id: 3)
enum ProbeResult {
    @fuzz_probe(id: 4)
    ok(@fuzz_probe(id: 5) value: int)
    @fuzz_probe(id: 6)
    empty
}

@fuzz_probe(id: 7)
class ProbeBox {
    @fuzz_probe(id: 8)
    value: int = 1

    @fuzz_probe(id: 9)
    fn read(@fuzz_probe(id: 10) amount: int) -> int {
        @fuzz_probe(id: 11, tags: ["local", "var"])
        var total: int = self.value + amount
        return total
    }
}

@fuzz_probe(id: 12)
extern "C" let external_count: int

@fuzz_probe(id: 13)
@fuzz_probe(id: 14, note: "repeat")
@source_probe
fn main() {
    @fuzz_probe(id: 15)
    let item: Item = Item { value: 2 }
}
