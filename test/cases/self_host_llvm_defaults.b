import std.io

class Basket {
    label: string = "unset"
    items: List<int> = []
    tags: Map<string, int> = {}
    blob: Bytes = new Bytes(3)
    limit: int = 8_388_608
    ratio: float = 2.5
    price: decimal = 1.25
    open: bool = false

    fn init(move label: string) {
        self.label = move label
    }
}

fn main() {
    var basket: Basket = new Basket("mine")
    basket.items.push(4)
    basket.tags["a"] = 1
    io.println("{basket.label} {basket.items.len()} {basket.tags.len()} {basket.blob.len()} {basket.limit} {basket.ratio} {basket.price} {basket.open}")
}
