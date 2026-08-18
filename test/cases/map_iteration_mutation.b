fn main() {
    var values: Map<int, int> = {1: 10, 2: 20}
    for key: int, value: int in values {
        values[3] = key + value
    }
}
