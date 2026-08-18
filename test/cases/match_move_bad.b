class Item {
    value: int
    fn init(value: int) { self.value = value }
}

fn main() {
    let item: Item = new Item(1)
    match true {
        true => {
            let taken: Item = move item
        },
        false => {},
    }
    let bad: int = item.value
}
