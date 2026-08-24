struct Mixed {
    required: int
    padding: int = 4
}

fn main() {
    let broken: Mixed = Mixed {}
}
