import std.io

struct Pair {
    left: i32
    right: i32
}

struct Event {
    label: string
    value: int
}

enum Key {
    pair(value: Pair)
    event(value: Event)
    empty
}

fn event(label: string, value: int) -> Event {
    return Event { label: label, value: value }
}

fn main() {
    var decimals: Map<decimal, string> = {}
    decimals[2.50] = "decimal"
    var floats: Map<float, int> = {}
    floats[0.0] = 7

    let first: Option<string> = some("bean")
    let same: Option<string> =
        some("BEAN".to_lower())
    var optional: Map<Option<string>, int> = {}
    optional[first] = 8
    optional[none] = 9

    var pairs: Map<Pair, Event> = {}
    pairs[Pair { left: 1, right: 2 }] =
        event("first", 12)
    pairs.set(
        Pair { left: 3, right: 4 },
        event("second", 34))
    let pair_keys: List<Pair> = pairs.keys()

    var arrays: OrderedMap<[i64; 2], int> = {}
    arrays[[5, 6]] = 56

    var enums: Map<Key, int> = {}
    enums[Key.pair(
        Pair { left: 7, right: 8 })] = 78
    enums[Key.event(event("same", 9))] = 9

    io.println("maps {decimals[2.5]} {floats.contains(0.0 - 0.0)} {optional[same]} {optional[none]} {pairs[Pair { left: 1, right: 2 }].label} {pairs.contains(Pair { left: 3, right: 4 })} {pair_keys.len()} {arrays[[5, 6]]} {enums[Key.pair(Pair { left: 7, right: 8 })]} {enums.contains(Key.event(event("SAME".to_lower(), 9)))}")
}
