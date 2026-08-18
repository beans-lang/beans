fn main() {
    let values: Map<string, int> = {"one": 1}
    for key: string in values { key }

    let list: List<int> = [1]
    for index: int, value: int in list { index + value }
}

async fn direct_async(values: Map<int, int>) {
    for key: int, value: int in values { key + value }
}
