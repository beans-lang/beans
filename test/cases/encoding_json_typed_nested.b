import std.encoding.json
import std.io

struct Storage {
    @json.name(value: "type")
    pub storage_type: string
    pub capacity_tb: float
}

struct Specs {
    pub storage: Option<Storage>
    pub connectivity: Option<List<string>>
    pub note: Option<string>
}

struct Stock {
    pub location: string
    pub quantity: u64
}

struct Item {
    pub sku: string
    pub tags: List<string>
    pub specs: Specs
    pub stock: List<Stock>
}

struct Store {
    pub name: string
}

struct Payload {
    pub store: Store
    pub inventory: List<Item>
}

fn show(text: string) {
    let decoded: Result<Payload> = json.decode(text)
    match decoded {
        ok(payload) => {
            io.println("{payload.store.name}: {payload.inventory.len()}")
            for item: Item in payload.inventory {
                io.println("{item.sku}: tags={item.tags.len()} stock={item.stock.len()}")
                match item.specs.storage {
                    some(value) => io.println("storage={value.storage_type}:{value.capacity_tb}"),
                    none => io.println("storage=none"),
                }
                match item.specs.connectivity {
                    some(value) => io.println("connectivity={value.len()}"),
                    none => io.println("connectivity=none"),
                }
                match item.specs.note {
                    some(value) => io.println("note={value}"),
                    none => io.println("note=none"),
                }
            }
        }
        err(error) => io.println("error: {error.kind}"),
    }
}

fn main() {
    show("\{\"store\":\{\"name\":\"TechNova\"\},\"inventory\":[\{\"sku\":\"LAP\",\"tags\":[\"fast\",\"portable\"],\"specs\":\{\"storage\":\{\"type\":\"SSD\",\"capacity_tb\":1.0\},\"connectivity\":null,\"note\":\"ready\"\},\"stock\":[\{\"location\":\"east\",\"quantity\":4\},\{\"location\":\"west\",\"quantity\":2\}]\},\{\"sku\":\"MOUSE\",\"tags\":[],\"specs\":\{\"storage\":null,\"connectivity\":[\"Bluetooth\",\"2.4GHz\"],\"note\":null\},\"stock\":[]\}]\}")
    show("\{\"store\":\{\"name\":\"bad\"\},\"inventory\":[\{\"sku\":\"x\",\"tags\":[],\"specs\":\{\"storage\":null,\"connectivity\":null,\"note\":null\},\"stock\":[1]\}]\}")
}
