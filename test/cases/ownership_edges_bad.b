interface Tag {
    fn id() -> int
}

unique class Ticket implements Tag {
    value: int

    fn init(value: int) { self.value = value }
    fn id() -> int { return self.value }
}

class Crate<T> {
    value: T

    fn init(value: T) { self.value = value }
    fn get() -> T { return self.value }
}

fn identity<T>(value: T) -> T {
    return value
}

fn branch_copy(source: List<int>) -> List<int> {
    return if true { source } else { [] }
}

fn match_copy(source: List<int>) -> List<int> {
    return match true {
        true => source,
        false => [],
    }
}

fn try_copy(source: Option<List<int>>) -> Option<List<int>> {
    let value: List<int> = source?
    return some(move value)
}

fn main() {
    let generic_source: List<int> = [1]
    let generic_copy: List<int> = identity(generic_source)
    let crate_source: List<int> = [9]
    let crate: Crate<List<int>> = new Crate(crate_source)
    let crate_copy: List<int> = crate.get()

    let branch_source: List<int> = [2]
    let branch_alias: List<int> = branch_copy(branch_source)
    let match_source: List<int> = [3]
    let match_alias: List<int> = match_copy(match_source)

    let option_source: Option<List<int>> = some([])
    let tried: Option<List<int>> = try_copy(option_source)
    let filtered: Option<List<int>> = option_source.filter(
        fn(value: List<int>) -> bool { return value.len() == 0 })
    let expected: List<int> = option_source.expect("list")
    let default_value: List<int> = []
    let fallback: List<int> = option_source.or(default_value)

    let result_value: Result<List<int>, string> = ok([])
    let recovered: List<int> = result_value.recover(
        fn(error: string) -> List<int> { return [] })
    let result_error: Result<int, List<int>> = err([])
    let custom_error_source: List<int> = []
    let copied_error: Result<int, List<int>> = err(custom_error_source)
    let mapped: Result<string, List<int>> = result_error.map(
        fn(value: int) -> string { return "{value}" })

    let boxed: Box<List<int>> = new Box([])
    let box_copy: List<int> = boxed.get()
    let arena: Arena<List<int>> = new Arena(1)
    let arena_copy: Option<List<int>> = arena.get(0)
    let shared: Shared<List<int>> = new Shared([])
    let shared_copy: List<int> = shared.get()

    let nested: List<List<int>> = [[1], [2]]
    let nested_slice: List<List<int>> = nested.slice(0, 1)
    let map: Map<string, List<int>> = {"one": [1]}
    let map_copy: Option<List<int>> = map.get("one")
    let indexed: List<int> = map["one"]
    let bad_key: Map<List<int>, int> = {[1]: 1}

    let arena_value: List<int> = [4]
    arena.add(arena_value)
    let channel: Channel<List<int>> = new Channel(1)
    let message: List<int> = [5]
    channel.send(message)

    let ticket: Ticket = new Ticket(1)
    let erased: Tag = move ticket
    let other: Ticket = new Ticket(2)
    let casted: Tag = (move other) as Tag
}
