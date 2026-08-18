fn main() {
    let values: List<int> = [1, 2, 3]
    for value: int in values.slice(1, 4) {
        let unused: int = value
    }
}
