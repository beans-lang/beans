fn main() {
    let values: Map<string, int> = {"one": 1}
    for key: string in values { key }

    let list: List<int> = [1]
    for index: int, value: int in list { index + value }
}
